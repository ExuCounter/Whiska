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

  describe "command/0 — what goes into settings.json" do
    test "points at the checked-in shim" do
      command = Install.command()

      assert command =~ "$CLAUDE_PROJECT_DIR"
      assert command =~ Install.shim_path()
    end

    test "names nothing specific to the machine that ran init" do
      # ADR-0056 checks this file into git so the rules travel with the repo.
      # An absolute path into one developer's home directory does not travel,
      # and leaks their username into a shared repo besides. Everything
      # machine-specific moved into the shim, which resolves it at run time.
      command = Install.command()

      refute command =~ System.user_home!()
      refute command =~ "/Users/"
      refute command =~ "/home/"
      refute command =~ "escript"
      refute command =~ ~r/erlang|otp/i
    end
  end

  describe "shim/0 — the script that resolves Whiska at run time" do
    test "is a shell script" do
      assert Install.shim() =~ ~r/\A#!/
      assert Install.shim() =~ "bash"
    end

    test "resolves the binary and the runtime when it runs, not when it is written" do
      shim = Install.shim()

      assert shim =~ "command -v escript"
      assert shim =~ ~s(hook "$@")
    end

    test "can be pointed elsewhere without editing it" do
      assert Install.shim() =~ "WHISKA_BIN"
      assert Install.shim() =~ "WHISKA_ESCRIPT"
    end

    test "names nothing specific to the machine that ran init" do
      shim = Install.shim()

      refute shim =~ System.user_home!()
      refute shim =~ "/Users/"
    end

    test "fails open when Whiska is not installed" do
      # Same trade as Whiska.Hook.PreToolUse makes on a malformed payload: a
      # missing binary must never brick every tool call in a session. Allow,
      # and complain on stderr.
      shim = Install.shim()

      assert shim =~ "exit 0"
      assert shim =~ ">&2"
    end
  end

  describe "merge/1 — writing into settings that already exist" do
    test "creates the hook block in empty settings" do
      merged = Install.merge(%{})

      assert [entry] = get_in(merged, ["hooks", "PreToolUse"])
      assert entry["matcher"] == Install.matcher()
      assert [%{"type" => "command", "command" => command}] = entry["hooks"]
      assert command == Install.command()
    end

    test "wires SessionStart to the same shim, with no matcher, so it fires on every source" do
      merged = Install.merge(%{})

      assert [%{"hooks" => [%{"type" => "command", "command" => command}]} = entry] =
               get_in(merged, ["hooks", "SessionStart"])

      refute Map.has_key?(entry, "matcher")
      assert command == Install.session_start_command()
      assert command =~ Install.shim_path()
      assert command =~ "session-start"
    end

    test "every hook merge wires is one entry with its own command, the doctor checks it, and unmerge takes it out" do
      for scope <- [:repo, :global] do
        expected = %{
          "PreToolUse" => Install.command(scope),
          "Stop" => Install.stop_command(scope),
          "UserPromptSubmit" => Install.prompt_command(scope),
          "SessionStart" => Install.session_start_command(scope)
        }

        merged = %{} |> Install.merge(scope) |> Install.merge(scope)

        assert Enum.sort(Map.keys(merged["hooks"])) == Enum.sort(Map.keys(expected)), "#{scope}"

        for {event, command} <- expected do
          assert [%{"hooks" => [%{"command" => ^command}]}] = merged["hooks"][event],
                 "#{scope}: #{event}"
        end

        unmerged = Install.unmerge(merged, nil)

        for event <- Map.keys(merged["hooks"]),
            do: assert(unmerged["hooks"][event] == [], "#{scope}: #{event}")
      end

      doctor_rows = Install.merge(%{}) |> Whiska.Doctor.hooks() |> Enum.map(& &1.name)
      assert Enum.sort(doctor_rows) == Enum.sort(Map.keys(Install.merge(%{})["hooks"]))
    end

    test "unmerge takes SessionStart back out and leaves someone else's entry" do
      theirs = %{"hooks" => [%{"type" => "command", "command" => "theirs.sh"}]}
      merged = Install.merge(%{"hooks" => %{"SessionStart" => [theirs]}})

      assert Install.unmerge(merged, nil)["hooks"]["SessionStart"] == [theirs]
    end

    test "leaves unrelated settings completely alone" do
      existing = %{"model" => "opus", "env" => %{"FOO" => "bar"}}

      merged = Install.merge(existing)

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

      merged = Install.merge(existing)

      assert merged["hooks"]["PostToolUse"] == existing["hooks"]["PostToolUse"]

      assert %{"matcher" => "Read"} =
               Enum.find(merged["hooks"]["PreToolUse"], &(&1["matcher"] == "Read"))

      assert Enum.any?(merged["hooks"]["PreToolUse"], &(&1["matcher"] == Install.matcher()))
    end

    test "is idempotent — re-running init does not stack duplicates" do
      once = Install.merge(%{})
      twice = Install.merge(once)
      thrice = Install.merge(twice)

      assert once == twice
      assert twice == thrice
      assert length(twice["hooks"]["PreToolUse"]) == 1
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

      merged = Install.merge(stale)

      assert [entry] = merged["hooks"]["PreToolUse"]
      assert entry["matcher"] == Install.matcher()
    end

    test "replaces an entry that hard-coded a machine path" do
      # The form `whiska init` wrote before the shim existed. Re-running init
      # has to migrate it in place, not leave two entries fighting.
      legacy = %{
        "hooks" => %{
          "PreToolUse" => [
            %{
              "matcher" => Install.matcher(),
              "hooks" => [
                %{
                  "type" => "command",
                  "command" =>
                    "/Users/someone/.asdf/installs/erlang/28.1.1/bin/escript" <>
                      " /Users/someone/.local/bin/whiska hook pre-tool-use"
                }
              ]
            }
          ]
        }
      }

      merged = Install.merge(legacy)

      assert [entry] = merged["hooks"]["PreToolUse"]
      assert [%{"command" => command}] = entry["hooks"]
      refute command =~ "/Users/someone"
      assert command == Install.command()
    end
  end

  describe "the shim, actually run" do
    # A hook does not necessarily inherit an interactive shell's PATH. That is
    # the whole reason the old install wrote absolute paths, and the shim only
    # earns its keep if it survives the same conditions.
    @stripped_path "/usr/bin:/bin"

    setup %{} do
      tmp = Path.join(System.tmp_dir!(), "whiska-shim-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf(tmp) end)

      shim = Path.join(tmp, "whiska.sh")
      File.write!(shim, Install.shim())
      File.chmod!(shim, 0o755)

      {:ok, tmp: tmp, shim: shim}
    end

    defp stub(tmp, name, body) do
      path = Path.join(tmp, name)
      File.write!(path, body)
      File.chmod!(path, 0o755)
      path
    end

    test "hands the binary to the runtime both overrides name", %{tmp: tmp, shim: shim} do
      whiska = stub(tmp, "whiska", "#!/bin/sh\nexit 0\n")
      escript = stub(tmp, "escript", ~s|#!/bin/sh\necho "RAN $*"\n|)

      {out, status} =
        System.cmd("bash", [shim, "pre-tool-use"],
          env: [{"WHISKA_BIN", whiska}, {"WHISKA_ESCRIPT", escript}, {"PATH", @stripped_path}],
          stderr_to_stdout: true
        )

      assert status == 0
      assert out =~ "RAN #{whiska} hook pre-tool-use"
    end

    test "finds escript without PATH or asdf on it" do
      # The regression that prompted this: binary found, runtime not, hook
      # silently stops enforcing. The shim has to look inside the version
      # manager's install directory itself, not just ask it.
      assert Install.shim() =~ "installs/erlang"
    end

    test "allows the call when no Whiska can be found at all", %{tmp: tmp, shim: shim} do
      # Run from outside any worktree: inside one, in a repo with a house, the
      # shim says so with exit 1 instead (Whiska.InstallShimCannotRunTest).
      {out, status} =
        System.cmd("bash", [shim],
          env: [
            {"WHISKA_BIN", Path.join(tmp, "does-not-exist")},
            {"WHISKA_ESCRIPT", ""},
            {"HOME", tmp},
            {"PATH", @stripped_path},
            {"CLAUDE_PROJECT_DIR", nil}
          ],
          cd: tmp,
          stderr_to_stdout: true
        )

      assert status == 0, "a missing Whiska must never brick a session"
      assert out =~ "whiska"
      refute out =~ "permissionDecision"
    end
  end
end
