defmodule Whiska.CLITest do
  # Serial: the code under test opens the house under the one VM-wide name `Whiska.Repo`
  # (the hook and `whiska mode`).
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Whiska.CLI

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-cli-#{System.unique_integer([:positive])}")
    main = Path.join(root, "myrepo")
    worktree = Path.join(main, "worktrees/feat-thing")
    File.mkdir_p!(Path.join(main, ".git"))
    File.mkdir_p!(worktree)
    File.write!(Path.join(worktree, ".git"), "gitdir: #{main}/.git/worktrees/feat-thing\n")
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, main: main, worktree: worktree}
  end

  describe "whiska hook pre-tool-use" do
    test "prints a deny decision to stdout", %{main: main, worktree: worktree} do
      payload =
        JSON.encode!(%{
          "cwd" => worktree,
          "tool_name" => "Write",
          "tool_input" => %{"file_path" => Path.join(main, "CONTEXT.md")}
        })

      out = capture_io(payload, fn -> assert CLI.run(["hook", "pre-tool-use"]) == 0 end)

      assert %{"hookSpecificOutput" => %{"permissionDecision" => "deny"}} = JSON.decode!(out)
    end

    test "prints nothing at all for an allowed call", %{worktree: worktree} do
      capture_io(fn -> CLI.run(["mode", "build"], worktree) end)

      payload =
        JSON.encode!(%{
          "cwd" => worktree,
          "tool_name" => "Write",
          "tool_input" => %{"file_path" => Path.join(worktree, "lib/fine.ex")}
        })

      out = capture_io(payload, fn -> assert CLI.run(["hook", "pre-tool-use"]) == 0 end)

      assert out == ""
    end

    test "exits 0 even when denying, since the decision is carried in the JSON", %{
      main: main,
      worktree: worktree
    } do
      payload =
        JSON.encode!(%{
          "cwd" => worktree,
          "tool_name" => "Write",
          "tool_input" => %{"file_path" => Path.join(main, "CONTEXT.md")}
        })

      capture_io(payload, fn -> assert CLI.run(["hook", "pre-tool-use"]) == 0 end)
    end
  end

  describe "--version" do
    test "reports the version" do
      out = capture_io(fn -> assert CLI.run(["--version"]) == 0 end)
      assert out =~ "0.0.1"
    end
  end

  describe "usage" do
    test "an unknown command explains itself and fails" do
      stderr = capture_io(:stderr, fn -> assert CLI.run(["nonsense"]) == 1 end)
      assert stderr =~ "hook pre-tool-use"
    end

    test "no arguments does the same" do
      stderr = capture_io(:stderr, fn -> assert CLI.run([]) == 1 end)
      assert stderr =~ "Usage"
    end
  end

  describe "whiska mode" do
    test "reports a fresh mouse as never shaped (ADR-0069)", %{worktree: worktree} do
      out = capture_io(fn -> assert CLI.run(["mode"], worktree) == 0 end)
      assert out =~ "unshaped"
    end

    test "switches a mouse to sniff and back", %{worktree: worktree} do
      capture_io(fn -> assert CLI.run(["mode", "sniff"], worktree) == 0 end)
      out = capture_io(fn -> assert CLI.run(["mode"], worktree) == 0 end)
      assert out =~ "sniff"

      capture_io(fn -> assert CLI.run(["mode", "build"], worktree) == 0 end)
      out = capture_io(fn -> assert CLI.run(["mode"], worktree) == 0 end)
      assert out =~ "build"
    end

    test "mints the mouse if it has never been seen", %{worktree: worktree} do
      refute File.exists?(Whiska.Marker.path(worktree))
      capture_io(fn -> assert CLI.run(["mode", "sniff"], worktree) == 0 end)
      assert File.exists?(Whiska.Marker.path(worktree))
    end

    test "refuses a mode that is not build or sniff", %{worktree: worktree} do
      stderr = capture_io(:stderr, fn -> assert CLI.run(["mode", "lurk"], worktree) == 1 end)
      assert stderr =~ "build"
      assert stderr =~ "sniff"
    end

    test "explains itself when run outside a worktree", %{main: main} do
      stderr = capture_io(:stderr, fn -> assert CLI.run(["mode"], main) == 1 end)
      assert stderr =~ "worktree"
    end
  end

  describe "whiska shape" do
    test "a sniff mouse is recorded as sniff and starts on sonnet", %{worktree: worktree} do
      out = capture_io(fn -> assert CLI.run(["shape", "sniff"], worktree) == 0 end)
      assert String.trim(out) == "sonnet"

      out = capture_io(fn -> assert CLI.run(["mode"], worktree) == 0 end)
      assert out =~ "sniff"
    end

    test "a build mouse keeps the person's own default model", %{worktree: worktree} do
      out = capture_io(fn -> assert CLI.run(["shape", "build"], worktree) == 0 end)
      assert String.trim(out) == ""
    end

    test "a spawn can name the model itself", %{worktree: worktree} do
      out =
        capture_io(fn -> assert CLI.run(["shape", "sniff", "--model", "opus"], worktree) == 0 end)

      assert String.trim(out) == "opus"
    end

    test "says what it recorded, on stderr, so stdout stays the model", %{worktree: worktree} do
      stderr =
        capture_io(:stderr, fn ->
          capture_io(fn -> assert CLI.run(["shape", "sniff"], worktree) == 0 end)
        end)

      assert stderr =~ "feat-thing is a sniff mouse on sonnet"
    end

    test "refuses a model it does not know", %{worktree: worktree} do
      stderr =
        capture_io(:stderr, fn ->
          assert CLI.run(["shape", "sniff", "--model", "gpt"], worktree) == 1
        end)

      assert stderr =~ "fable"
      refute File.exists?(Whiska.Marker.path(worktree))
    end

    test "refuses a mode that is not build or sniff", %{worktree: worktree} do
      stderr = capture_io(:stderr, fn -> assert CLI.run(["shape", "lurk"], worktree) == 1 end)
      assert stderr =~ "build or sniff"
    end

    test "fails outside a worktree, so a spawn stops before Claude starts", %{main: main} do
      capture_io(:stderr, fn -> assert CLI.run(["shape", "sniff"], main) == 1 end)
    end
  end

  describe "a branch name with a slash in it" do
    setup %{main: main} do
      nested = Path.join(main, "worktrees/feat/csv-data-page")
      File.mkdir_p!(nested)
      File.write!(Path.join(nested, ".git"), "gitdir: #{main}/.git/worktrees/csv-data-page\n")
      {:ok, nested: nested}
    end

    test "names the mouse after the whole branch", %{nested: nested} do
      out = capture_io(fn -> assert CLI.run(["mode"], nested) == 0 end)
      assert out =~ "feat/csv-data-page"
    end

    test "mints the marker inside the worktree, not beside it", %{main: main, nested: nested} do
      capture_io(fn -> assert CLI.run(["mode"], nested) == 0 end)

      assert File.exists?(Whiska.Marker.path(nested))
      refute File.exists?(Whiska.Marker.path(Path.join(main, "worktrees/feat")))
    end

    test "denies a write into a sibling branch's worktree", %{main: main, nested: nested} do
      sibling = Path.join(main, "worktrees/feat/other-page")
      File.mkdir_p!(sibling)

      payload =
        JSON.encode!(%{
          "cwd" => nested,
          "tool_name" => "Write",
          "tool_input" => %{"file_path" => Path.join(sibling, "app.ex")}
        })

      out = capture_io(payload, fn -> assert CLI.run(["hook", "pre-tool-use"]) == 0 end)

      assert %{"hookSpecificOutput" => %{"permissionDecision" => "deny"}} = JSON.decode!(out)
    end

    test "still denies a write into the main checkout", %{main: main, nested: nested} do
      payload =
        JSON.encode!(%{
          "cwd" => nested,
          "tool_name" => "Write",
          "tool_input" => %{"file_path" => Path.join(main, "CONTEXT.md")}
        })

      out = capture_io(payload, fn -> assert CLI.run(["hook", "pre-tool-use"]) == 0 end)

      assert %{"hookSpecificOutput" => %{"permissionDecision" => "deny"}} = JSON.decode!(out)
    end

    test "allows a write inside its own worktree", %{nested: nested} do
      capture_io(fn -> CLI.run(["mode", "build"], nested) end)

      payload =
        JSON.encode!(%{
          "cwd" => nested,
          "tool_name" => "Write",
          "tool_input" => %{"file_path" => Path.join(nested, "app/routes/csv.ex")}
        })

      assert capture_io(payload, fn -> assert CLI.run(["hook", "pre-tool-use"]) == 0 end) == ""
    end
  end

  describe "whiska init" do
    test "writes the hook into a repo with no settings yet", %{main: main} do
      capture_io(fn -> assert CLI.run(["init"], main) == 0 end)

      settings = JSON.decode!(File.read!(Path.join(main, ".claude/settings.json")))
      assert [entry] = settings["hooks"]["PreToolUse"]
      assert entry["matcher"] == Whiska.Install.matcher()
      assert [%{"command" => command}] = entry["hooks"]
      assert command == Whiska.Install.command()
    end

    test "preserves settings that are already there", %{main: main} do
      File.mkdir_p!(Path.join(main, ".claude"))

      File.write!(
        Path.join(main, ".claude/settings.json"),
        JSON.encode!(%{
          "model" => "opus",
          "hooks" => %{
            "PostToolUse" => [%{"matcher" => "Bash", "hooks" => [%{"command" => "mine.sh"}]}]
          }
        })
      )

      capture_io(fn -> assert CLI.run(["init"], main) == 0 end)

      settings = JSON.decode!(File.read!(Path.join(main, ".claude/settings.json")))
      assert settings["model"] == "opus"
      assert [%{"matcher" => "Bash"}] = settings["hooks"]["PostToolUse"]
      assert [_whiska] = settings["hooks"]["PreToolUse"]
    end

    test "is safe to re-run", %{main: main} do
      capture_io(fn -> assert CLI.run(["init"], main) == 0 end)
      first = File.read!(Path.join(main, ".claude/settings.json"))

      capture_io(fn -> assert CLI.run(["init"], main) == 0 end)

      assert File.read!(Path.join(main, ".claude/settings.json")) == first
    end

    test "writes readable JSON a human can review before committing it", %{main: main} do
      capture_io(fn -> assert CLI.run(["init"], main) == 0 end)
      raw = File.read!(Path.join(main, ".claude/settings.json"))

      assert raw =~ "\n", "settings.json should be formatted, not one long line"
      assert String.ends_with?(raw, "\n")
    end

    test "refuses rather than destroying a settings file it cannot parse", %{main: main} do
      File.mkdir_p!(Path.join(main, ".claude"))
      File.write!(Path.join(main, ".claude/settings.json"), "{ this is not json")

      stderr = capture_io(:stderr, fn -> assert CLI.run(["init"], main) == 1 end)

      assert stderr =~ "could not"
      assert File.read!(Path.join(main, ".claude/settings.json")) == "{ this is not json"
    end

    test "tells you what it did and what to do next", %{main: main} do
      out = capture_io(fn -> assert CLI.run(["init"], main) == 0 end)

      assert out =~ ".claude/settings.json"
      assert out =~ "git add"
    end

    test "writes the shim script and makes it executable", %{main: main} do
      capture_io(fn -> assert CLI.run(["init"], main) == 0 end)

      shim = Path.join(main, Whiska.Install.shim_path())

      assert File.exists?(shim), "init must write #{Whiska.Install.shim_path()}"
      assert File.read!(shim) == Whiska.Install.shim()

      mode = File.stat!(shim).mode
      assert Bitwise.band(mode, 0o100) != 0, "the shim has to be executable to run"
    end

    test "leaves nothing about this machine in the file that gets committed", %{main: main} do
      capture_io(fn -> assert CLI.run(["init"], main) == 0 end)

      raw = File.read!(Path.join(main, ".claude/settings.json"))

      refute raw =~ System.user_home!()
      refute raw =~ "escript"
    end

    test "migrates a settings file that still names a machine path", %{main: main} do
      File.mkdir_p!(Path.join(main, ".claude"))

      File.write!(
        Path.join(main, ".claude/settings.json"),
        JSON.encode!(%{
          "hooks" => %{
            "PreToolUse" => [
              %{
                "matcher" => Whiska.Install.matcher(),
                "hooks" => [
                  %{"type" => "command", "command" => "/Users/someone/whiska hook pre-tool-use"}
                ]
              }
            ]
          }
        })
      )

      capture_io(fn -> assert CLI.run(["init"], main) == 0 end)

      raw = File.read!(Path.join(main, ".claude/settings.json"))
      refute raw =~ "/Users/someone"

      settings = JSON.decode!(raw)
      assert [_only_one] = settings["hooks"]["PreToolUse"]
    end
  end

  describe "whiska init, run a second time with nothing to change" do
    # Claude Code reads settings.json once, at startup, and `whiska doctor`
    # compares the main session's age against when that file last changed. A
    # re-init that rewrote identical bytes would move that clock and make every
    # live session look stale, so an unchanged file is left alone.
    test "leaves the files it already wrote untouched", %{main: main} do
      capture_io(fn -> assert CLI.run(["init"], main) == 0 end)

      touched = [
        Path.join(main, ".claude/settings.json"),
        Path.join(main, Whiska.Install.shim_path()),
        Path.join(main, Whiska.Install.statusline_path())
      ]

      long_ago = System.os_time(:second) - 86_400
      for path <- touched, do: File.touch!(path, long_ago)

      capture_io(fn -> assert CLI.run(["init"], main) == 0 end)

      for path <- touched do
        assert File.stat!(path, time: :posix).mtime == long_ago,
               "#{Path.basename(path)} was rewritten with the same contents"
      end
    end

    test "a mode that drifted wider is still put back — init is the repair", %{main: main} do
      capture_io(fn -> assert CLI.run(["init"], main) == 0 end)
      shim = Path.join(main, Whiska.Install.shim_path())
      File.chmod!(shim, 0o777)

      capture_io(fn -> assert CLI.run(["init"], main) == 0 end)

      assert Bitwise.band(File.stat!(shim).mode, 0o7777) == 0o755
    end

    test "still writes a file whose contents have changed", %{main: main} do
      capture_io(fn -> assert CLI.run(["init"], main) == 0 end)
      path = Path.join(main, Whiska.Install.statusline_path())
      File.write!(path, "#!/usr/bin/env bash\n# an older one\n")
      File.touch!(path, System.os_time(:second) - 86_400)

      capture_io(fn -> assert CLI.run(["init"], main) == 0 end)

      assert File.read!(path) == Whiska.Install.statusline_script()
    end
  end
end
