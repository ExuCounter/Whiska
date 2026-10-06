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

  # The global install as the doctor sees it: which of its pieces are on disk.
  defp installed, do: %{hooks?: true, session_start?: true, statusline?: true, skills?: true}

  defp absent,
    do: %{hooks?: false, session_start?: false, statusline?: false, skills?: false}

  describe "global/1 — is the global install there, and whole" do
    test "nothing installed is not a failure; a repo may simply carry its own" do
      assert %Check{status: :ok, name: "global install"} = Doctor.global(absent())
    end

    test "every piece there reads as on" do
      assert %Check{status: :ok, detail: detail} = Doctor.global(installed())
      assert detail =~ "~/.claude"
    end

    test "the hooks missing, SessionStart included, is a half-written install" do
      assert %Check{status: :warn, detail: detail} =
               Doctor.global(%{installed() | hooks?: false})

      assert detail =~ "hooks"
    end

    test "a half-written install is a warning naming what is missing" do
      assert %Check{status: :warn, detail: detail, fix: "whiska init --global"} =
               Doctor.global(%{installed() | skills?: false})

      assert detail =~ "skills"
    end
  end

  describe "hooks/2 — a repo covered by the global install" do
    test "a global install from before SessionStart: the other hooks still pass, and the fix is the global init" do
      checks = Doctor.hooks(%{}, %{installed() | session_start?: false})

      assert %Check{status: :ok} = find(checks, "PreToolUse")
      assert %Check{status: :ok} = find(checks, "Stop")

      assert %Check{status: :fail, fix: "whiska init --global"} = find(checks, "SessionStart")
    end

    test "a repo with no hooks of its own passes when the global ones are there" do
      checks = Doctor.hooks(%{}, installed())

      assert %Check{status: :ok, detail: pre} = find(checks, "PreToolUse")
      assert %Check{status: :ok, detail: stop} = find(checks, "Stop")
      assert %Check{status: :ok, detail: start} = find(checks, "SessionStart")
      assert pre =~ "globally"
      assert stop =~ "globally"
      assert start =~ "globally"
    end

    test "a repo with no hooks of its own still fails when nothing is global" do
      checks = Doctor.hooks(%{}, absent())

      assert %Check{status: :fail} = find(checks, "PreToolUse")
      assert %Check{status: :fail} = find(checks, "Stop")
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
      # A repo set up before SessionStart existed: its own three hooks, no fourth.
      older = update_in(Install.merge(%{}), ["hooks"], &Map.delete(&1, "SessionStart"))

      assert %Check{status: :fail, detail: detail, fix: "whiska init"} =
               find(Doctor.hooks(older, installed()), "SessionStart")

      refute detail =~ "globally"
    end
  end

  describe "statusline/2" do
    test "no project line is fine when the global one is Whiska's" do
      assert %Check{status: :ok, detail: detail} = Doctor.statusline(%{}, installed())
      assert detail =~ "globally"
    end

    test "no project line and no global one is still a warning" do
      assert %Check{status: :warn} = Doctor.statusline(%{}, absent())
    end
  end
end
