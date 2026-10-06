defmodule Whiska.Owl.HouseBoardTest do
  @moduledoc """
  The house keeps its board on disk (ADR-0051), so the statusline can draw what
  every mouse is doing without starting anything.
  """
  use ExUnit.Case, async: true

  import Mox

  alias Whiska.Herdr.Mock, as: Herdr
  alias Whiska.Owl.House
  alias Whiska.Storage
  alias Whiska.Watch.Ink
  alias Whiska.Watch.Snapshot

  setup :verify_on_exit!

  @socket "/fake/herdr.sock"

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-board-#{System.unique_integer([:positive])}")
    main = Path.join(root, "myrepo")
    worktree = Path.join([main, "worktrees", "feat-a"])
    File.mkdir_p!(Path.join(main, ".git"))
    File.mkdir_p!(worktree)

    {:ok, handle} = Storage.open(main, name: nil)
    {:ok, _} = Storage.record_mouse(%{mouse_id: "ma", path: worktree, branch: "feat-a"})
    Storage.close(handle)

    on_exit(fn ->
      File.rm_rf!(root)
      File.rm_rf!(Snapshot.path(main))
      File.rm_rf!(Snapshot.main_path(main))
    end)

    {:ok, main: main, worktree: worktree}
  end

  # The house calls herdr from its own process, from `init/1` on, so it is
  # allowed in by name before it starts — which is what lets this file run async.
  defp start_house(opts) do
    name = :"house-#{System.unique_integer([:positive])}"
    allow(Herdr, self(), fn -> Process.whereis(name) end)
    start_supervised!({House, [name: name] ++ opts})
  end

  defp without_ticker(board),
    do: board |> String.replace("·", "") |> String.replace(~r/working  \d+s  /u, "working  ")

  defp pane(cwd, status),
    do: %{pane_id: "w1:p1", cwd: cwd, agent: "claude", agent_status: status}

  defp fake_subscription, do: {:ok, spawn(fn -> receive do: (:stop -> :ok) end)}

  defp open(main, opts) do
    opts =
      Keyword.merge(
        [
          main_checkout: main,
          herdr_socket: @socket,
          backstop_ms: 60_000,
          board_ms: 30,
          panes_ms: 30
        ],
        opts
      )

    pid = start_house(opts)
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

  defp board(main), do: Ink.plain(written_board(main))

  defp written_board(main) do
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

  test "shows an answer its mouse has not taken on that mouse's row", %{
    main: main,
    worktree: worktree
  } do
    {:ok, handle} = Storage.open(main, name: nil)
    {:ok, q} = Storage.record_question(%{mouse_id: "ma", text: "which?", kind: "needs-decision"})
    {:ok, _} = Storage.answer(q.id, "SQLite")
    {:ok, _} = Storage.mark_not_taken(q.id, DateTime.utc_now())
    Storage.close(handle)

    stub(Herdr, :list_panes, fn @socket -> {:ok, [pane(worktree, "idle")]} end)
    stub(Herdr, :subscribe, fn @socket, _subs, _listener -> fake_subscription() end)

    open(main, [])

    assert board(main) =~ "answer ##{q.id} not taken"
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

  test "writes the board more often than it asks herdr for panes", %{
    main: main,
    worktree: worktree
  } do
    asked = :counters.new(1, [])

    stub(Herdr, :list_panes, fn @socket ->
      :counters.add(asked, 1, 1)
      {:ok, [pane(worktree, "working")]}
    end)

    stub(Herdr, :subscribe, fn @socket, _subs, _listener -> fake_subscription() end)

    house = open(main, board_ms: 60_000, panes_ms: 60_000)
    written = written_board(main)
    before = :counters.get(asked, 1)

    send(house, :board)
    assert House.sync(house) == :ok

    refute File.read!(Snapshot.path(main)) == written
    assert :counters.get(asked, 1) == before
  end

  test "a write between herdr asks re-times the last board rather than reading it again", %{
    main: main,
    worktree: worktree
  } do
    stub(Herdr, :list_panes, fn @socket -> {:ok, [pane(worktree, "working")]} end)
    stub(Herdr, :subscribe, fn @socket, _subs, _listener -> fake_subscription() end)

    house = open(main, board_ms: 60_000, panes_ms: 60_000)
    assert board(main) =~ "🐭 feat-a"

    in_house(house, fn -> {:ok, _} = Storage.mark_dead("ma") end)
    send(house, :board)
    assert House.sync(house) == :ok

    assert Ink.plain(File.read!(Snapshot.path(main))) =~ "🐭 feat-a"
  end

  # Dropping a worktree closes its herdr workspace, and herdr reports that as
  # `workspace_closed` alone — no `pane_closed` for the panes inside it
  # (checked against the live socket on 2026-10-04). Nothing else here
  # notices until the backstop, a minute later.
  test "a closed workspace takes its mouse off the board at once", %{
    main: main,
    worktree: worktree
  } do
    listed = :counters.new(1, [])

    stub(Herdr, :list_panes, fn @socket ->
      if :counters.get(listed, 1) == 0, do: {:ok, [pane(worktree, "idle")]}, else: {:ok, []}
    end)

    stub(Herdr, :subscribe, fn @socket, _subs, _listener -> fake_subscription() end)

    house = open(main, board_ms: 60_000, panes_ms: 60_000)
    assert board(main) =~ "🐭 feat-a"

    :counters.put(listed, 1, 1)
    send(house, {:herdr_event, "workspace_closed", %{"workspace_id" => "w1"}})
    assert House.sync(house) == :ok

    refute Ink.plain(File.read!(Snapshot.path(main))) =~ "feat-a"
    in_house(house, fn -> assert %DateTime{} = Storage.mouse("ma").died_at end)
  end

  test "a working row's ticker moves on every write, so a frozen board shows", %{
    main: main,
    worktree: worktree
  } do
    stub(Herdr, :list_panes, fn @socket -> {:ok, [pane(worktree, "working")]} end)
    stub(Herdr, :subscribe, fn @socket, _subs, _listener -> fake_subscription() end)

    open(main, [])
    written = written_board(main)
    first = Ink.plain(written)

    second =
      eventually(fn ->
        case File.read!(Snapshot.path(main)) do
          ^written -> :retry
          other -> {:ok, Ink.plain(other)}
        end
      end)

    assert [_, first_dots] = Regex.run(~r/working  \S+  (·+)/u, first)
    assert [_, second_dots] = Regex.run(~r/working  \S+  (·+)/u, second)
    refute first_dots == second_dots
    # The elapsed column is the wall clock, and a second can tick between two
    # writes; nothing else on the row may move.
    assert without_ticker(first) == without_ticker(second)
  end

  test "a board the house could not write leaves the dots where they were", %{
    main: main,
    worktree: worktree
  } do
    stub(Herdr, :list_panes, fn @socket -> {:ok, [pane(worktree, "working")]} end)
    stub(Herdr, :subscribe, fn @socket, _subs, _listener -> fake_subscription() end)

    house = open(main, board_ms: 5_000)
    assert [_, dots] = Regex.run(~r/working  \S+  (·+)/u, board(main))

    blocked = Snapshot.path(main) <> ".tmp"
    File.mkdir_p!(blocked)
    on_exit(fn -> File.rm_rf!(blocked) end)

    send(house, :board)
    assert House.sync(house) == :ok

    assert [_, ^dots] = Regex.run(~r/working  \S+  (·+)/u, File.read!(Snapshot.path(main)))

    File.rm_rf!(blocked)
    send(house, :board)
    assert House.sync(house) == :ok

    assert [_, next] = Regex.run(~r/working  \S+  (·+)/u, File.read!(Snapshot.path(main)))
    assert String.length(next) == String.length(dots) + 1
  end

  test "herdr failing mid-tick does not take the house down with it", %{
    main: main,
    worktree: worktree
  } do
    asked = :counters.new(1, [])

    stub(Herdr, :list_panes, fn @socket ->
      if :counters.get(asked, 1) == 1, do: raise("herdr blew up")
      {:ok, [pane(worktree, "working")]}
    end)

    stub(Herdr, :subscribe, fn @socket, _subs, _listener -> fake_subscription() end)

    house = open(main, board_ms: 20)
    assert board(main) =~ "🐭 feat-a"

    :counters.put(asked, 1, 1)
    Process.sleep(60)
    :counters.put(asked, 1, 0)

    assert House.sync(house) == :ok
    assert Process.alive?(house)
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

  # Which pane the questions go to, beside the board the statusline already
  # reads, so a session can tell whether it is the one (ADR-0065).
  describe "the main session's pane, beside the board" do
    test "is written with the board", %{main: main, worktree: worktree} do
      stub(Herdr, :list_panes, fn @socket -> {:ok, [pane(worktree, "working")]} end)
      stub(Herdr, :subscribe, fn @socket, _subs, _listener -> fake_subscription() end)

      {:ok, handle} = Storage.open(main, name: nil)
      :ok = Storage.set_main_pane("w1:p9")
      Storage.close(handle)

      open(main, [])
      assert board(main) =~ "🐭 feat-a"

      assert eventually(fn ->
               case File.read(Snapshot.main_path(main)) do
                 {:ok, "w1:p9"} -> {:ok, :written}
                 _ -> :retry
               end
             end) == :written
    end

    test "is empty while no main session is recorded", %{main: main, worktree: worktree} do
      stub(Herdr, :list_panes, fn @socket -> {:ok, [pane(worktree, "working")]} end)
      stub(Herdr, :subscribe, fn @socket, _subs, _listener -> fake_subscription() end)

      open(main, [])
      assert board(main) =~ "🐭 feat-a"

      assert File.read!(Snapshot.main_path(main)) == ""
    end
  end

  # A hold is never silent (ADR-0058): the board says why, where the person is
  # already looking.
  describe "a held queue" do
    setup %{main: main, worktree: worktree} do
      stub(Herdr, :list_panes, fn @socket -> {:ok, [pane(worktree, "working")]} end)
      stub(Herdr, :subscribe, fn @socket, _subs, _listener -> fake_subscription() end)

      stub(Herdr, :pane, fn @socket, "w1:p2" ->
        {:ok, %{pane_id: "w1:p2", cwd: "/main", agent: "claude", agent_status: "working"}}
      end)

      {:ok, handle} = Storage.open(main, name: nil)
      :ok = Storage.set_main_pane("w1:p2")

      {:ok, _} =
        Storage.record_question(%{mouse_id: "ma", text: "which db?", kind: "needs-decision"})

      Storage.close(handle)
      :ok
    end

    test "says why nothing is being delivered once the hold has lasted", %{main: main} do
      open(main, hold_notice_ms: 0)

      eventually(fn ->
        if File.read!(Snapshot.path(main)) =~ "gated: this session is mid-turn",
          do: {:ok, :said},
          else: :retry
      end)
    end

    test "says nothing while the hold is younger than the fuse", %{main: main} do
      house = open(main, hold_notice_ms: 60_000)
      assert House.sync(house) == :ok

      refute board(main) =~ "held"
    end
  end

  defp in_house(house, fun) do
    Storage.point_at(House.repo(house))
    fun.()
  end
end
