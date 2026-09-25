defmodule Whiska.CLITest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Whiska.CLI

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-cli-#{System.unique_integer([:positive])}")
    main = Path.join(root, "myrepo")
    worktree = Path.join(main, "worktrees/feat-thing")
    File.mkdir_p!(Path.join(main, ".git"))
    File.mkdir_p!(worktree)
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
    test "reports build for a fresh mouse", %{worktree: worktree} do
      out = capture_io(fn -> assert CLI.run(["mode"], worktree) == 0 end)
      assert out =~ "build"
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
end
