defmodule Whiska.Shape.RulesTest do
  @moduledoc """
  `priv/models.json` is read when Whiska is compiled, so a file that is wrong
  has to stop the build, and say what is wrong in words a person can fix.
  """
  use ExUnit.Case, async: true

  alias Whiska.Shape.Rules

  @shipped "priv/models.json" |> File.read!() |> JSON.decode!()

  setup do
    dir = Path.join(System.tmp_dir!(), "whiska-rules-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp write(dir, rules) do
    path = Path.join(dir, "models.json")
    File.write!(path, if(is_binary(rules), do: rules, else: JSON.encode!(rules)))
    path
  end

  defp refused(dir, rules) do
    path = write(dir, rules)
    error = assert_raise RuntimeError, fn -> Rules.load!(path) end
    assert error.message =~ path, "the message should name the file"
    error.message
  end

  defp put(rules, keys, value), do: put_in(rules, Enum.map(keys, &Access.key(&1)), value)

  test "the shipped file loads, as the person wrote it", %{dir: dir} do
    assert Rules.load!(write(dir, @shipped)) == @shipped
  end

  test "a catch-all that names no model or effort is allowed", %{dir: dir} do
    rules =
      @shipped
      |> update_in(
        ["model", "choose"],
        &List.replace_at(&1, -1, %{"when" => "anything else", "use" => nil})
      )
      |> update_in(
        ["effort", "choose"],
        &List.replace_at(&1, -1, %{"when" => "anything else", "use" => nil})
      )
      |> put(["model", "fallback"], [])

    assert Rules.load!(write(dir, rules)) == rules
  end

  describe "a file the build refuses" do
    test "is not JSON", %{dir: dir} do
      assert refused(dir, "{\"modes\": ") =~ "is not JSON"
    end

    test "has a field nobody agreed to", %{dir: dir} do
      # A `may_write` beside the modes was rejected: the hook decides what sniff
      # may do, and a field here claiming to would be a lie.
      message = refused(dir, Map.put(@shipped, "may_write", %{"sniff" => false}))
      assert message =~ ~s("may_write")
      assert message =~ ~s("modes", "model" and "effort")
    end

    test "is missing a part", %{dir: dir} do
      assert refused(dir, Map.delete(@shipped, "effort")) =~ ~s(missing "effort")
    end

    test "describes a mode the hook does not enforce, or not both", %{dir: dir} do
      assert refused(dir, put(@shipped, ["modes", "review"], "a third kind")) =~
               "exactly build and sniff"

      assert refused(dir, update_in(@shipped, ["modes"], &Map.delete(&1, "sniff"))) =~
               "exactly build and sniff"
    end

    test "leaves a mode undescribed", %{dir: dir} do
      assert refused(dir, put(@shipped, ["modes", "sniff"], "")) =~ ~s(modes.sniff)
    end

    test "has no rules to choose from", %{dir: dir} do
      assert refused(dir, put(@shipped, ["effort", "choose"], [])) =~ "effort.choose"
    end

    test "has a rule that is not a when and a use", %{dir: dir} do
      message =
        refused(
          dir,
          update_in(@shipped, ["model", "choose"], &[%{"when" => "always"} | &1])
        )

      assert message =~ "model.choose, rule 1"
      assert message =~ ~s("when" and a "use")
    end

    test "uses something that is not one plain word", %{dir: dir} do
      for bad <- ["two words", "opus;rm -rf ~", "--effort", "opus[1m]", "", 3] do
        message =
          refused(
            dir,
            update_in(@shipped, ["model", "choose"], &[%{"when" => "x", "use" => bad} | &1])
          )

        assert message =~ "model.choose, rule 1", inspect(bad)
        assert message =~ "one plain word", inspect(bad)
      end
    end

    test "leaves a model to the person's default anywhere but the catch-all", %{dir: dir} do
      # A flag left off means the catch-all, so a null earlier has no way to reach Claude.
      message =
        refused(
          dir,
          update_in(@shipped, ["model", "choose"], &[%{"when" => "x", "use" => nil} | &1])
        )

      assert message =~ "model.choose, rule 1"
      assert message =~ "only the catch-all may be null"
    end

    test "says a rule or a mode in nothing but spaces", %{dir: dir} do
      assert refused(dir, put(@shipped, ["modes", "build"], "   ")) =~ "modes.build"

      assert refused(
               dir,
               update_in(
                 @shipped,
                 ["effort", "choose"],
                 &[%{"when" => "  ", "use" => "low"} | &1]
               )
             ) =~ "effort.choose, rule 1"
    end

    test "names a rule with a key too many as exactly that", %{dir: dir} do
      message =
        refused(
          dir,
          update_in(
            @shipped,
            ["model", "choose"],
            &[%{"when" => "x", "use" => "m1", "may_write" => false} | &1]
          )
        )

      assert message =~ ~s(must be exactly a "when" and a "use")
    end

    test "does not end on the catch-all", %{dir: dir} do
      message =
        refused(dir, update_in(@shipped, ["effort", "choose"], &Enum.drop(&1, -1)))

      assert message =~ "effort.choose"
      assert message =~ ~s(must end on the catch-all, "when": "anything else")
    end

    test "puts the catch-all anywhere but last, where it would hide the rest", %{dir: dir} do
      message =
        refused(dir, update_in(@shipped, ["model", "choose"], &Enum.reverse/1))

      assert message =~ "model.choose, rule 1"
      assert message =~ "only the last rule"
    end

    test "falls back to something that is not a list of plain words", %{dir: dir} do
      assert refused(dir, put(@shipped, ["model", "fallback"], "opus,sonnet")) =~
               "model.fallback"

      assert refused(dir, put(@shipped, ["model", "fallback"], ["opus", "so net"])) =~
               "model.fallback"
    end
  end

  test "a module that reads a malformed file does not compile", %{dir: dir} do
    # What `Whiska.Shape` does with the real file: read it in the module body,
    # so the error is the build's.
    path = write(dir, update_in(@shipped, ["effort", "choose"], &Enum.drop(&1, -1)))

    error =
      assert_raise RuntimeError, fn ->
        Code.compile_string("""
        defmodule Whiska.Shape.RulesTest.Reader do
          @rules Whiska.Shape.Rules.load!(#{inspect(path)})
        end
        """)
      end

    assert error.message =~ "must end on the catch-all"
    refute Code.ensure_loaded?(Whiska.Shape.RulesTest.Reader)
  end
end
