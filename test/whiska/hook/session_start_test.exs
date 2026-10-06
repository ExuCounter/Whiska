defmodule Whiska.Hook.SessionStartTest do
  @moduledoc """
  The rules a session starts with, chosen by its role (ADR-next-rules-arrive-by-role):
  none outside herdr, the main session's in herdr, a mouse's in a worktree.
  """
  # Identity reads HERDR_PANE_ID from the OS env, which is process-wide.
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
    System.put_env("HERDR_PANE_ID", "w1:p2")

    rules = c.worktree |> start(herdr(c.home)) |> context()

    assert rules =~ "# Whiska: rules for the main session"
    refute rules =~ Marker.render(:done)
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
