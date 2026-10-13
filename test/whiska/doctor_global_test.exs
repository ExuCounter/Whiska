defmodule Whiska.DoctorGlobalTest do
  @moduledoc """
  `whiska doctor` with the global install in play (ADR-0056).

  A repo with no `.claude/` of its own is correctly set up when the global
  install covers it, so the hook checks have to know whether it is there —
  otherwise the doctor reports two failures for a machine where nothing is
  wrong.
  """
  use ExUnit.Case, async: true

  alias Whiska.Doctor
  alias Whiska.Doctor.Check
  alias Whiska.Install

  defp find(checks, name), do: Enum.find(checks, &(&1.name == name))

  # The global install as the doctor sees it: whether its hooks are on disk.
  defp installed, do: %{hooks?: true}

  defp absent, do: %{hooks?: false}

  # The SessionStart entry an older init wrote, which nothing answers now.
  @older_session_start %{
    "hooks" => [
      %{
        "type" => "command",
        "command" => ~s|bash "$CLAUDE_PROJECT_DIR/.claude/hooks/whiska.sh" session-start|
      }
    ]
  }

  describe "global/1 — is the global install there, and whole" do
    test "nothing installed is not a failure; a repo may simply carry its own" do
      assert %Check{status: :ok, name: "global install"} = Doctor.global(absent())
    end

    test "the hooks there reads as on" do
      assert %Check{status: :ok, detail: detail} = Doctor.global(installed())
      assert detail =~ "~/.claude"
    end

    test "a retired skill still on disk is named, fixed by the global init" do
      state = Map.put(installed(), :retired_present, [".claude/skills/whiska-questions/SKILL.md"])

      assert %Check{status: :warn, detail: detail, fix: "whiska init --global"} =
               Doctor.global(state)

      assert detail =~ "whiska-questions"
      assert detail =~ "retired"
    end

    test "an older install's SessionStart hook is named, even with the hooks gone" do
      state = Map.put(absent(), :retired_present, [".claude/settings.json SessionStart"])

      assert %Check{status: :warn, detail: detail, fix: "whiska init --global"} =
               Doctor.global(state)

      assert detail =~ "SessionStart"
    end
  end

  describe "hooks/2 — a repo covered by the global install" do
    test "a repo with no hooks of its own passes when the global ones are there" do
      checks = Doctor.hooks(%{}, installed())

      assert %Check{status: :ok, detail: pre} = find(checks, "PreToolUse")
      assert %Check{status: :ok, detail: stop} = find(checks, "Stop")
      assert pre =~ "globally"
      assert stop =~ "globally"
      refute find(checks, "SessionStart")
    end

    test "a repo with no hooks of its own still fails when nothing is global" do
      checks = Doctor.hooks(%{}, absent())

      assert %Check{status: :fail} = find(checks, "PreToolUse")
      assert %Check{status: :fail} = find(checks, "Stop")
    end

    test "a SessionStart hook an older init wired here is named, fixed by init" do
      settings = put_in(Install.merge(%{}), ["hooks", "SessionStart"], [@older_session_start])

      assert %Check{status: :warn, detail: detail, fix: "whiska init"} =
               find(Doctor.hooks(settings, installed()), "SessionStart")

      assert detail =~ "retired"
    end

    test "a repo with its own hooks passes either way, and says the repo's win" do
      checks = Doctor.hooks(Install.merge(%{}), installed())

      assert %Check{status: :ok, detail: detail} = find(checks, "PreToolUse")
      assert detail =~ "this repo"
      refute detail =~ "twice"
    end

    test "a repo's own hooks are still checked against the current version" do
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

      assert %Check{status: :fail} = find(Doctor.hooks(stale, installed()), "PreToolUse")
    end

    test "a repo wiring Whiska itself gets nothing from the global copy, which stands down there" do
      # A repo set up before UserPromptSubmit existed: its own two hooks, no third.
      older = update_in(Install.merge(%{}), ["hooks"], &Map.delete(&1, "UserPromptSubmit"))

      assert %Check{status: :fail, detail: detail, fix: "whiska init"} =
               find(Doctor.hooks(older, installed()), "UserPromptSubmit")

      refute detail =~ "globally"
    end
  end
end
