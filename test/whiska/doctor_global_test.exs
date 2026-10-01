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
  defp installed, do: %{block?: true, hooks?: true, statusline?: true, skills?: true}
  defp absent, do: %{block?: false, hooks?: false, statusline?: false, skills?: false}

  describe "global/1 — is the global install there, and whole" do
    test "nothing installed is not a failure; a repo may simply carry its own" do
      assert %Check{status: :ok, name: "global install"} = Doctor.global(absent())
    end

    test "all four pieces reads as on" do
      assert %Check{status: :ok, detail: detail} = Doctor.global(installed())
      assert detail =~ "~/.claude"
    end

    test "a block left behind by an uninstall is not a half-written install" do
      # `remove/1` keeps the outer markers whenever a part the person claimed
      # with `keep` survives (ADR-0045), so the markers alone mean nothing.
      assert %Check{status: :ok, detail: detail} = Doctor.global(%{absent() | block?: true})
      assert detail =~ "not installed"
    end

    test "a half-written install is a warning naming what is missing" do
      assert %Check{status: :warn, detail: detail, fix: "whiska init --global"} =
               Doctor.global(%{installed() | skills?: false})

      assert detail =~ "skills"
    end
  end

  describe "hooks/2 — a repo covered by the global install" do
    test "a repo with no hooks of its own passes when the global ones are there" do
      checks = Doctor.hooks(%{}, installed())

      assert %Check{status: :ok, detail: pre} = find(checks, "PreToolUse")
      assert %Check{status: :ok, detail: stop} = find(checks, "Stop")
      assert pre =~ "globally"
      assert stop =~ "globally"
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
