defmodule Whiska.InstallTest do
  use ExUnit.Case, async: true

  alias Whiska.Install

  describe "matcher/0" do
    test "covers every tool the rules can actually deny" do
      matcher = Install.matcher()

      # Bash matters as much as the edit tools now: sniff mode denies mutating
      # commands, and containment denies ones reaching into the main checkout.
      # A matcher without it would silently never fire those rules.
      for tool <- ~w(Write Edit MultiEdit NotebookEdit Bash) do
        assert matcher =~ tool, "#{tool} is enforced but not matched"
      end
    end

    test "leaves out tools that can never be denied" do
      # ADR-0033: not running at all beats running fast, and reads are never
      # policed in any mode.
      for tool <- ~w(Read Grep Glob WebFetch TodoWrite) do
        refute Install.matcher() =~ tool
      end
    end
  end

  describe "command/1" do
    test "spells out both the Erlang runtime and the binary" do
      command = Install.command("/opt/whiska")

      # An escript starts with #!/usr/bin/env escript, so it only runs when
      # escript is on PATH — and a hook does not necessarily inherit one.
      assert command =~ "/opt/whiska"
      assert command =~ "hook pre-tool-use"
      assert command =~ "bin/escript"
    end

    test "never wraps the call in a shell" do
      refute Install.command("/opt/whiska") =~ ~r/\bbash\b|\bsh -c\b/
    end
  end

  describe "merge/2 — writing into settings that already exist" do
    test "creates the hook block in empty settings" do
      merged = Install.merge(%{}, "/opt/whiska")

      assert [entry] = get_in(merged, ["hooks", "PreToolUse"])
      assert entry["matcher"] == Install.matcher()
      assert [%{"type" => "command", "command" => command}] = entry["hooks"]
      assert command =~ "/opt/whiska"
    end

    test "leaves unrelated settings completely alone" do
      existing = %{"model" => "opus", "env" => %{"FOO" => "bar"}}

      merged = Install.merge(existing, "/opt/whiska")

      assert merged["model"] == "opus"
      assert merged["env"] == %{"FOO" => "bar"}
    end

    test "leaves other people's hooks alone" do
      existing = %{
        "hooks" => %{
          "PostToolUse" => [
            %{"matcher" => "Bash", "hooks" => [%{"command" => "their-script.sh"}]}
          ],
          "PreToolUse" => [%{"matcher" => "Read", "hooks" => [%{"command" => "audit.sh"}]}]
        }
      }

      merged = Install.merge(existing, "/opt/whiska")

      assert merged["hooks"]["PostToolUse"] == existing["hooks"]["PostToolUse"]

      assert %{"matcher" => "Read"} =
               Enum.find(merged["hooks"]["PreToolUse"], &(&1["matcher"] == "Read"))

      assert Enum.any?(merged["hooks"]["PreToolUse"], &(&1["matcher"] == Install.matcher()))
    end

    test "is idempotent — re-running init does not stack duplicates" do
      once = Install.merge(%{}, "/opt/whiska")
      twice = Install.merge(once, "/opt/whiska")
      thrice = Install.merge(twice, "/opt/whiska")

      assert once == twice
      assert twice == thrice
      assert length(twice["hooks"]["PreToolUse"]) == 1
    end

    test "updates an existing whiska entry in place when the path changes" do
      old = Install.merge(%{}, "/old/whiska")
      new = Install.merge(old, "/new/whiska")

      assert [entry] = new["hooks"]["PreToolUse"]
      assert [%{"command" => command}] = entry["hooks"]
      assert command =~ "/new/whiska"
      refute command =~ "/old/whiska"
    end

    test "recognises its own entry even after the matcher is widened" do
      # A hook installed before Bash was policed must be corrected, not duplicated.
      stale = %{
        "hooks" => %{
          "PreToolUse" => [
            %{
              "matcher" => "Write|Edit",
              "hooks" => [%{"type" => "command", "command" => "/opt/whiska hook pre-tool-use"}]
            }
          ]
        }
      }

      merged = Install.merge(stale, "/opt/whiska")

      assert [entry] = merged["hooks"]["PreToolUse"]
      assert entry["matcher"] == Install.matcher()
    end
  end
end
