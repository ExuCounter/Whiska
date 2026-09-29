defmodule Whiska.Owl.HouseBoardTest do
  @moduledoc """
  The house keeps its board on disk (ADR-0051), so the statusline can draw what
  every mouse is doing without starting anything.
  """
  use ExUnit.Case, async: false

  import Mox

  alias Whiska.Herdr.Mock, as: Herdr
  alias Whiska.Owl.House
  alias Whiska.Storage
  alias Whiska.Watch.Snapshot

  setup :set_mox_global
  setup :verify_on_exit!

  @socket "/fake/herdr.sock"

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-board-#{System.unique_integer([:positive])}")
    main = Path.join(root, "myrepo")
    worktree = Path.join([main, "worktrees", "feat-a"])
    File.mkdir_p!(Path.join(main, ".git"))
    File.mkdir_p!(worktree)

    {:ok, handle} = Storage.open(main, name: :seed)
    {:ok, _} = Storage.record_mouse(%{mouse_id: "ma", path: worktree, branch: "feat-a"})
    Storage.close(handle)

    on_exit(fn ->
      File.rm_rf!(root)
      File.rm_rf!(Snapshot.path(main))
    end)

    {:ok, main: main, worktree: worktree}
  end

  defp pane(cwd, status),
    do: %{pane_id: "w1:p1", cwd: cwd, agent: "claude", agent_status: status}

  defp fake_subscription, do: {:ok, spawn(fn -> receive do: (:stop -> :ok) end)}

  defp open(main, opts) do
    opts =
      Keyword.merge(
        [main_checkout: main, herdr_socket: @socket, backstop_ms: 60_000, board_ms: 30],
        opts
      )

    pid = start_supervised!({House, opts})
    House.sync(pid)
    pid
  end

  defp eventually(fun, tries \\ 100) do
    case fun.() do
      {:ok, value} ->
        value

      :retry when tries > 0 ->
        Process.sleep(10)
        eventually(fun, tries - 1)

      :retry ->
        flunk("the board never arrived")
    end
  end

  defp board(main) do
    eventually(fn ->
      case File.read(Snapshot.path(main)) do
        {:ok, text} -> {:ok, text}
        {:error, :enoent} -> :retry
      end
    end)
  end

  test "writes the board as soon as the house opens", %{main: main, worktree: worktree} do
    stub(Herdr, :list_panes, fn @socket -> {:ok, [pane(worktree, "working")]} end)
    stub(Herdr, :subscribe, fn @socket, _subs, _listener -> fake_subscription() end)

    open(main, [])

    assert board(main) =~ "🐭 feat-a"
  end

  test "keeps it current on its own timer", %{main: main, worktree: worktree} do
    status = :counters.new(1, [])
    :counters.put(status, 1, 0)

    stub(Herdr, :list_panes, fn @socket ->
      said = if :counters.get(status, 1) == 0, do: "working", else: "idle"
      {:ok, [pane(worktree, said)]}
    end)

    stub(Herdr, :subscribe, fn @socket, _subs, _listener -> fake_subscription() end)

    open(main, [])
    assert board(main) =~ "working"

    :counters.put(status, 1, 1)

    eventually(fn ->
      if File.read!(Snapshot.path(main)) =~ "idle", do: {:ok, :changed}, else: :retry
    end)
  end

  test "a house with nothing running leaves an empty board, not the last one", %{
    main: main,
    worktree: worktree
  } do
    stub(Herdr, :list_panes, fn @socket -> {:ok, [pane(worktree, "working")]} end)
    stub(Herdr, :subscribe, fn @socket, _subs, _listener -> fake_subscription() end)

    house = open(main, [])
    assert board(main) =~ "🐭 feat-a"

    in_house(house, fn -> {:ok, _} = Storage.mark_dead("ma") end)

    eventually(fn ->
      if File.read!(Snapshot.path(main)) == "", do: {:ok, :emptied}, else: :retry
    end)
  end

  defp in_house(house, fun) do
    Storage.point_at(House.repo(house))
    fun.()
  end
end
