defmodule Whiska.InstallOwlTest do
  @moduledoc "What init wires for the owl slice: the Stop hook, through the same shim."
  use ExUnit.Case, async: true

  alias Whiska.Install

  describe "the shim carries the hook name as its argument" do
    test "the committed PreToolUse command names the event, not the shim alone" do
      assert Install.command() =~ Install.shim_path()
      assert String.ends_with?(Install.command(), " pre-tool-use")
    end

    test "the Stop command goes through the same shim" do
      assert Install.stop_command() =~ Install.shim_path()
      assert String.ends_with?(Install.stop_command(), " stop")
      refute Install.stop_command() =~ "/Users/"
    end

    test "the shim passes whatever it was given on to whiska hook" do
      assert Install.shim() =~ ~s(hook "$@")
      refute Install.shim() =~ "hook pre-tool-use"
    end
  end

  describe "merge/1 — the Stop hook" do
    test "adds a Stop entry beside PreToolUse" do
      merged = Install.merge(%{})

      # Two of them now: the doorstep writer, and the repo's own review loop
      # (ADR-0042), which Claude Code runs in parallel with it.
      assert [entry, _review_loop] = get_in(merged, ["hooks", "Stop"])
      assert [%{"type" => "command", "command" => command}] = entry["hooks"]
      assert command == Install.stop_command()
    end

    test "is idempotent" do
      once = Install.merge(%{})
      twice = Install.merge(once)
      assert once == twice
      assert length(twice["hooks"]["Stop"]) == 2
    end

    test "leaves other people's Stop hooks alone" do
      existing = %{"hooks" => %{"Stop" => [%{"hooks" => [%{"command" => "their-notify.sh"}]}]}}
      merged = Install.merge(existing)

      assert length(merged["hooks"]["Stop"]) == 3
      assert Enum.any?(merged["hooks"]["Stop"], &(&1 == hd(existing["hooks"]["Stop"])))
    end

    test "replaces a PreToolUse entry written before the shim took an argument" do
      stale = %{
        "hooks" => %{
          "PreToolUse" => [
            %{
              "matcher" => Install.matcher(),
              "hooks" => [
                %{
                  "type" => "command",
                  "command" => ~s|bash "$CLAUDE_PROJECT_DIR/.claude/hooks/whiska.sh"|
                }
              ]
            }
          ]
        }
      }

      merged = Install.merge(stale)
      assert [%{"hooks" => [%{"command" => command}]}] = merged["hooks"]["PreToolUse"]
      assert command == Install.command()
    end
  end
end
