defmodule Whiska.ShapeTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Whiska.Shape

  @rules "priv/models.json" |> File.read!() |> JSON.decode!()

  # The last rule of each list is the catch-all, which applies when a spawn
  # names nothing.
  @model @rules["model"]["choose"] |> List.last() |> Map.fetch!("use")
  @effort @rules["effort"]["choose"] |> List.last() |> Map.fetch!("use")
  @fallback @rules["model"]["fallback"]
  @window @rules["model"]["autocompact"]

  @models (Enum.map(@rules["model"]["choose"], & &1["use"]) ++ @fallback)
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()

  defp shape(mode, model, effort), do: %{mode: mode, model: model, effort: effort}

  describe "parse/1" do
    test "a mode alone takes the catch-all model and effort" do
      for mode <- ~w(build sniff) do
        assert Shape.parse([mode]) == {:ok, shape(mode, @model, @effort)}
      end
    end

    test "a model or an effort named on the command line wins, with no rule applied" do
      assert Shape.parse(["sniff", "--model", "some-model", "--effort", "max"]) ==
               {:ok, shape("sniff", "some-model", "max")}

      assert Shape.parse(["build", "--effort", "low", "--model", "claude-some-model-9"]) ==
               {:ok, shape("build", "claude-some-model-9", "low")}

      assert Shape.parse(["build", "--effort", "low"]) == {:ok, shape("build", @model, "low")}
    end

    test "accepts any plain word: Claude Code decides which models exist, not Whiska" do
      assert {:ok, %{model: "a-model-nobody-has-heard-of"}} =
               Shape.parse(["build", "--model", "a-model-nobody-has-heard-of"])
    end

    test "refuses anything that is not one plain word, so the output stays safe in a shell" do
      for bad <- ["two words", "x;reboot", "$(id)", "--effort", "opus[1m]", "Opus", ""] do
        assert {:error, message} = Shape.parse(["sniff", "--model", bad]), inspect(bad)
        assert message =~ "one plain word"
        assert {:error, _} = Shape.parse(["sniff", "--effort", bad]), inspect(bad)
      end
    end

    test "refuses a flag named twice, an unknown flag, and a flag with no value" do
      assert {:error, message} = Shape.parse(~w(build --model a --model b))
      assert message =~ "--model is named twice"

      assert {:error, message} = Shape.parse(~w(build --temperature 2))
      assert message =~ "whiska shape <build|sniff>"

      assert {:error, _} = Shape.parse(~w(build --effort))
    end

    test "refuses a mode that is not build or sniff, and no mode at all" do
      assert {:error, message} = Shape.parse(["lurk"])
      assert message =~ "build or sniff"

      assert {:error, message} = Shape.parse([])
      assert message =~ "whiska shape <build|sniff>"
    end
  end

  describe "claude_args/1" do
    test "carries the model, the effort and the fallback chain" do
      assert Shape.claude_args(shape("sniff", "m1", "xhigh"), ["m2", "m3"]) ==
               ~w(--model m1 --effort xhigh --fallback-model m2,m3)
    end

    test "falls back past the chosen model, never onto it" do
      # Retrying the model that just failed is no fallback at all.
      assert Shape.claude_args(shape("build", "m1", "low"), ["m1", "m2"], %{}) ==
               ~w(--model m1 --effort low --fallback-model m2)

      assert Shape.claude_args(shape("build", "m1", "low"), ["m1"], %{}) ==
               ~w(--model m1 --effort low)
    end

    test "is empty when there is nothing to name" do
      assert Shape.claude_args(shape("build", nil, nil), [], %{}) == []
    end

    test "leaves out only what is not named" do
      assert Shape.claude_args(shape("build", nil, "medium"), ["m1"], %{}) ==
               ~w(--effort medium --fallback-model m1)
    end

    test "uses the fallback chain from priv/models.json by default" do
      args = Shape.claude_args(shape("sniff", "not-in-the-chain", nil))

      assert args == [
               "--model",
               "not-in-the-chain",
               "--fallback-model",
               Enum.join(@fallback, ",")
             ]
    end

    test "a build mouse gets its model's auto-compact window, else the default's" do
      windows = %{"m1" => 123_000, "default" => 200_000}

      assert Shape.claude_args(shape("build", "m1", nil), [], windows) ==
               ~w(--model m1 --autocompact 123000)

      assert Shape.claude_args(shape("build", "m2", nil), [], windows) ==
               ~w(--model m2 --autocompact 200000)

      assert Shape.claude_args(shape("build", nil, nil), [], windows) ==
               ~w(--autocompact 200000)
    end

    test "a sniff mouse gets no window, so it keeps Claude Code's default" do
      windows = %{"default" => 200_000}

      refute "--autocompact" in Shape.claude_args(shape("sniff", "m1", nil), [], windows)
      refute "--autocompact" in Shape.claude_args(shape("sniff", "m1", nil))
    end

    test "priv/models.json gives build mice 300000 and haiku 100000" do
      assert @window["default"] == 300_000
      assert @window["haiku"] == 100_000

      assert Shape.claude_args(shape("build", "haiku", nil), []) ==
               ~w(--model haiku --autocompact 100000)

      assert Shape.claude_args(shape("build", "opus", nil), []) ==
               ~w(--model opus --autocompact 300000)
    end
  end

  describe "window/1, the auto-compact window a mouse's context is measured against" do
    test "is its model's, else the default's, whatever its mode" do
      assert Shape.window("haiku") == 100_000
      assert Shape.window("opus") == 300_000
      assert Shape.window(nil) == 300_000
    end
  end

  describe "claude_args/1, plain words" do
    test "is only ever plain words, so splitting it in any shell is safe" do
      for mode <- ~w(build sniff), {:ok, shape} <- [Shape.parse([mode])] do
        line = Enum.join(Shape.claude_args(shape), " ")
        assert line =~ ~r/\A[a-z0-9 ,-]*\z/
      end
    end
  end

  test "rules/0 is priv/models.json, exactly as the build read it" do
    assert Shape.rules() == File.read!("priv/models.json")
  end

  describe "describe/1" do
    test "says the mode, the model and the effort" do
      assert Shape.describe(shape("sniff", "m1", "xhigh")) == "a sniff mouse on m1, xhigh effort"
    end

    test "says your default when the shape names none" do
      assert Shape.describe(shape("build", nil, nil)) ==
               "a build mouse on your default model, your default effort"
    end
  end

  describe "label/1" do
    test "is the shape, short, for a listing" do
      assert Shape.label(shape("sniff", "m1", "xhigh")) == "sniff on m1, xhigh effort"
      assert Shape.label(shape("build", "m1", nil)) == "build on m1"
      assert Shape.label(shape("build", nil, nil)) == "build"
    end
  end
end
