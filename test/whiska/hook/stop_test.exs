defmodule Whiska.Hook.StopTest do
  @moduledoc """
  The doorstep writer (ADR-0036): reads one Stop payload, leaves one entry in
  the house, exits. No socket, no database, no decision.
  """
  use ExUnit.Case, async: true

  alias Whiska.Doorstep
  alias Whiska.Doorstep.Entry
  alias Whiska.Hook.Stop
  alias Whiska.Marker

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-stop-#{System.unique_integer([:positive])}")
    main = Path.join(root, "myrepo")
    worktree = Path.join(main, "worktrees/feat-thing")
    File.mkdir_p!(Path.join(main, ".git"))
    File.mkdir_p!(Path.join(worktree, "lib"))
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, main: main, worktree: worktree}
  end

  defp payload(fields), do: JSON.encode!(fields)

  test "leaves the whole final message on the house's doorstep, stamped", %{
    main: main,
    worktree: worktree
  } do
    text = "Two options.\n\n[worktree-status: needs-decision] pick one"

    assert :ok = Stop.run(payload(%{"cwd" => worktree, "last_assistant_message" => text}))

    {:ok, mouse_id} = Marker.read_or_mint(worktree)

    assert [{_, %Entry{} = entry}] = Doorstep.waiting(main)
    assert entry.mouse_id == mouse_id
    assert entry.branch == "feat-thing"
    assert entry.worktree_root == worktree
    assert entry.text == text
    assert DateTime.diff(DateTime.utc_now(), entry.stamped_at, :second) < 5
  end

  test "a session sitting in a subfolder still lands in the right house", %{
    main: main,
    worktree: worktree
  } do
    :ok =
      Stop.run(payload(%{"cwd" => Path.join(worktree, "lib"), "last_assistant_message" => "hi"}))

    assert [{_, %Entry{worktree_root: ^worktree}}] = Doorstep.waiting(main)
  end

  test "writes unconditionally — no marker is still an entry (ADR-0009)", %{
    main: main,
    worktree: worktree
  } do
    :ok =
      Stop.run(payload(%{"cwd" => worktree, "last_assistant_message" => "stopped, no marker"}))

    assert [{_, %Entry{text: "stopped, no marker"}}] = Doorstep.waiting(main)
  end

  test "mints the mouse's marker file if this is the first it has been seen", %{
    worktree: worktree
  } do
    refute File.exists?(Marker.path(worktree))
    :ok = Stop.run(payload(%{"cwd" => worktree, "last_assistant_message" => "x"}))
    assert File.exists?(Marker.path(worktree))
  end

  test "is a no-op outside a worktree — the main session stops all the time", %{main: main} do
    assert :ok = Stop.run(payload(%{"cwd" => main, "last_assistant_message" => "x"}))
    assert Doorstep.waiting(main) == []
    refute File.exists?(Doorstep.path(main))
  end

  test "an empty message is still a stop worth recording", %{main: main, worktree: worktree} do
    :ok = Stop.run(payload(%{"cwd" => worktree}))
    assert [{_, %Entry{text: ""}}] = Doorstep.waiting(main)
  end

  test "a malformed payload is a loud no-op, never a crash", %{main: main} do
    assert :ok = Stop.run("{not json")
    assert Doorstep.waiting(main) == []
  end
end
