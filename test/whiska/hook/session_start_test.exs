defmodule Whiska.Hook.SessionStartTest do
  @moduledoc """
  The rules a session starts with, chosen by its role (ADR-0081):
  none outside herdr, the main session's in herdr, a mouse's in a worktree.
  """
  # Serial: the setup clears HERDR_PANE_ID in the OS env, which is process-wide;
  # the hook reads it from the environment it is handed.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Whiska.CLI
  alias Whiska.Question.Marker

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-start-#{System.unique_integer([:positive])}")
    main = Path.join(root, "myrepo")
    worktree = Path.join(main, "worktrees/feat-thing")
    home = Path.join(root, "home")
    File.mkdir_p!(Path.join(main, ".git"))
    File.mkdir_p!(worktree)
    File.mkdir_p!(Path.join(home, ".claude"))
    File.write!(Path.join(worktree, ".git"), "gitdir: #{main}/.git/worktrees/feat-thing\n")

    pane = System.get_env("HERDR_PANE_ID")
    System.delete_env("HERDR_PANE_ID")

    on_exit(fn ->
      File.rm_rf!(root)
      if pane, do: System.put_env("HERDR_PANE_ID", pane), else: System.delete_env("HERDR_PANE_ID")
    end)

    {:ok, main: main, worktree: worktree, home: home}
  end

  defp start(cwd, env) do
    payload = JSON.encode!(%{"cwd" => cwd, "hook_event_name" => "SessionStart"})

    capture_io(payload, fn ->
      assert CLI.session_start(env) == 0
    end)
  end

  defp context(output) do
    assert %{
             "hookSpecificOutput" => %{
               "hookEventName" => "SessionStart",
               "additionalContext" => rules
             }
           } = JSON.decode!(output)

    rules
  end

  defp herdr(home), do: %{"HERDR_ENV" => "1", "HOME" => home}

  test "a mouse starts with the marker and the finish trigger, and no spawn routing", c do
    rules = c.worktree |> start(herdr(c.home)) |> context()

    assert rules =~ Marker.render(:done)
    assert rules =~ Marker.render(:needs_decision)
    assert rules =~ "whiska-finish"
    assert rules =~ "**Grill.**"
    refute rules =~ "spawn-worktree"
    refute rules =~ "herdr worktree list"
  end

  test "the main session starts with routing and delivery, and no marker", c do
    rules = c.main |> start(herdr(c.home)) |> context()

    assert rules =~ "herdr worktree list"
    assert rules =~ "spawn-worktree"
    assert rules =~ "whiska reply <id>"
    assert rules =~ "**Grill.**"
    refute rules =~ Marker.render(:done)
    refute rules =~ "whiska-finish"
  end

  test "a session in the pane the house records as main is the main session, wherever it started",
       c do
    {:ok, handle} = Whiska.Storage.open(c.main)
    :ok = Whiska.Storage.set_main_pane("w1:p2")
    Whiska.Storage.close(handle)

    rules = c.worktree |> start(Map.put(herdr(c.home), "HERDR_PANE_ID", "w1:p2")) |> context()

    assert rules =~ "# Whiska: rules for the main session"
    refute rules =~ Marker.render(:done)
  end

  test "a mouse compacted after its shell moved still gets a mouse's rules, read from where it started",
       c do
    transcript = Path.join(c.worktree, "session.jsonl")
    File.write!(transcript, JSON.encode!(%{"type" => "user", "cwd" => c.worktree}))

    payload =
      JSON.encode!(%{
        "cwd" => c.main,
        "transcript_path" => transcript,
        "hook_event_name" => "SessionStart",
        "source" => "compact"
      })

    output = capture_io(payload, fn -> assert CLI.session_start(herdr(c.home)) == 0 end)

    assert context(output) =~ Marker.render(:done)
  end

  test "the project directory Claude Code names is where a project's keep is read", c do
    File.write!(Path.join(c.worktree, "CLAUDE.md"), """
    <!-- whiska:finish:start keep -->
    <!-- whiska:finish:end -->
    """)

    payload =
      JSON.encode!(%{"cwd" => Path.join(c.worktree, "lib"), "hook_event_name" => "SessionStart"})

    env = Map.put(herdr(c.home), "CLAUDE_PROJECT_DIR", c.worktree)
    output = capture_io(payload, fn -> assert CLI.session_start(env) == 0 end)

    refute context(output) =~ "## Before a turn is done"
    assert context(output) =~ Marker.render(:done)
  end

  test "under the global install a repo's own CLAUDE.md cannot hold a part back", c do
    File.write!(Path.join(c.worktree, "CLAUDE.md"), """
    <!-- whiska:finish:start keep -->
    <!-- whiska:finish:end -->
    <!-- whiska:marker:start keep -->
    <!-- whiska:marker:end -->
    """)

    payload = JSON.encode!(%{"cwd" => c.worktree, "hook_event_name" => "SessionStart"})
    env = Map.put(herdr(c.home), "CLAUDE_PROJECT_DIR", c.worktree)

    output = capture_io(payload, fn -> assert CLI.session_start(env, :global) == 0 end)

    assert context(output) =~ "## Before a turn is done"
    assert context(output) =~ Marker.render(:done)

    File.write!(Path.join(c.home, ".claude/CLAUDE.md"), """
    <!-- whiska:finish:start keep -->
    <!-- whiska:finish:end -->
    """)

    output = capture_io(payload, fn -> assert CLI.session_start(env, :global) == 0 end)
    refute context(output) =~ "## Before a turn is done"
  end

  test "with no transcript to read, the role comes from the project dir, not where the shell went",
       c do
    payload =
      JSON.encode!(%{
        "cwd" => c.worktree,
        "hook_event_name" => "SessionStart",
        "source" => "clear"
      })

    env = Map.put(herdr(c.home), "CLAUDE_PROJECT_DIR", c.main)

    output = capture_io(payload, fn -> assert CLI.session_start(env) == 0 end)

    assert context(output) =~ "# Whiska: rules for the main session"
  end

  test "outside herdr a session starts with nothing at all", c do
    assert start(c.worktree, %{"HOME" => c.home}) == ""
    assert start(c.main, %{"HOME" => c.home}) == ""
  end

  test "a part the person keeps in a CLAUDE.md is left out of what is injected", c do
    File.write!(Path.join(c.home, ".claude/CLAUDE.md"), """
    <!-- whiska:start -->
    <!-- whiska:report:start keep -->
    My own report rules.
    <!-- whiska:report:end -->
    <!-- whiska:end -->
    """)

    kept = c.worktree |> start(herdr(c.home)) |> context()
    File.rm!(Path.join(c.home, ".claude/CLAUDE.md"))
    shipped = c.worktree |> start(herdr(c.home)) |> context()

    assert shipped =~ "## How a mouse writes its message"
    refute kept =~ "## How a mouse writes its message"
    assert kept =~ "whiska-finish"
  end

  test "a keep in the project's own CLAUDE.md counts too", c do
    File.write!(Path.join(c.main, "CLAUDE.md"), """
    <!-- whiska:delivery:start keep -->
    <!-- whiska:delivery:end -->
    """)

    rules = c.main |> start(herdr(c.home)) |> context()

    refute rules =~ "## How a mouse's question reaches the person"
    assert rules =~ "herdr worktree list"
  end

  test "a payload that will not parse injects nothing and still exits 0", c do
    output =
      capture_io("not json", fn ->
        assert CLI.session_start(herdr(c.home)) == 0
      end)

    assert output == ""
  end
end
