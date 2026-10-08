defmodule Whiska.Owl.HouseSidebarTest do
  @moduledoc """
  The house keeps each mouse's line in herdr's sidebar
  (ADR-0082): it reports the line
  on the mouse's workspace, sends it again whenever herdr no longer holds it,
  and re-sorts the mice only when one starts or stops needing the person.

  herdr is a fake that remembers what it was told, the way the real server
  does until it restarts, so a restart is the fake forgetting.
  """
  use ExUnit.Case, async: true

  import Mox

  alias Whiska.Herdr.Mock, as: Herdr
  alias Whiska.Owl.House
  alias Whiska.Storage

  setup :verify_on_exit!

  @socket "/fake/herdr.sock"

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-sidebar-#{System.unique_integer([:positive])}")
    main = Path.join(root, "myrepo")
    worktree = Path.join([main, "worktrees", "feat-a"])
    File.mkdir_p!(Path.join(main, ".git"))
    File.mkdir_p!(worktree)

    {:ok, handle} = Storage.open(main, name: nil)
    {:ok, _} = Storage.record_mouse(%{mouse_id: "ma", path: worktree, branch: "feat-a"})
    Storage.close(handle)

    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, main: main, worktree: worktree}
  end

  defp start_house(opts) do
    name = :"house-#{System.unique_integer([:positive])}"
    allow(Herdr, self(), fn -> Process.whereis(name) end)
    start_supervised!({House, [name: name] ++ opts})
  end

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

  defp fake_subscription, do: {:ok, spawn(fn -> receive do: (:stop -> :ok) end)}

  defp pane(cwd, status, workspace_id),
    do: %{
      pane_id: workspace_id <> ":p1",
      workspace_id: workspace_id,
      cwd: cwd,
      agent: "claude",
      agent_status: status
    }

  # herdr as far as the sidebar goes: workspaces that hold whatever tokens they
  # were last told, and tell the test each time they are told something.
  defp fake_herdr(workspaces) do
    test = self()
    {:ok, held} = Agent.start_link(fn -> %{} end)

    stub(Herdr, :workspaces, fn @socket ->
      tokens = Agent.get(held, & &1)

      {:ok,
       for {ws, n} <- Enum.with_index(workspaces, 1) do
         Map.merge(ws, %{number: n, tokens: Map.get(tokens, ws.workspace_id, %{})})
       end}
    end)

    stub(Herdr, :report_metadata, fn @socket, ws, sent, _ttl_ms ->
      Agent.update(held, fn all ->
        kept =
          all |> Map.get(ws, %{}) |> Map.merge(sent) |> Map.reject(fn {_, v} -> is_nil(v) end)

        Map.put(all, ws, kept)
      end)

      send(test, {:reported, ws, sent})
      :ok
    end)

    stub(Herdr, :move_block, fn @socket, ids, before ->
      send(test, {:moved, ids, before})
      {:ok, []}
    end)

    held
  end

  defp main_ws(main), do: %{workspace_id: "w1", path: main, linked?: false}
  defp mouse_ws(id, path), do: %{workspace_id: id, path: path, linked?: true}

  describe "a mouse waiting on the person" do
    setup %{main: main, worktree: worktree} do
      {:ok, handle} = Storage.open(main, name: nil)
      :ok = Storage.set_main_pane("w1:p2")

      {:ok, q} =
        Storage.record_question(%{mouse_id: "ma", text: "which db?", kind: "needs-decision"})

      Storage.close(handle)

      stub(Herdr, :list_panes, fn @socket -> {:ok, [pane(worktree, "idle", "w2")]} end)
      stub(Herdr, :subscribe, fn @socket, _subs, _listener -> fake_subscription() end)

      # The main session is mid-turn, so delivery holds and types nothing.
      stub(Herdr, :pane, fn @socket, "w1:p2" ->
        {:ok, %{pane_id: "w1:p2", cwd: main, agent: "claude", agent_status: "working"}}
      end)

      {:ok, q: q}
    end

    test "has its line sent again once herdr has lost it", %{
      main: main,
      worktree: worktree,
      q: q
    } do
      held = fake_herdr([main_ws(main), mouse_ws("w2", worktree)])
      line = "🐭 ##{q.id} · waiting on you"

      open(main, [])

      assert_receive {:reported, "w2", %{"whiska" => ^line, "whiska_q" => "which db?"}}, 1_000

      # herdr still holds it: nothing to send, however many times the house looks.
      refute_receive {:reported, "w2", _}, 200

      # herdr's server restarted, and everything reported to it is gone.
      Agent.update(held, fn _ -> %{} end)

      assert_receive {:reported, "w2", %{"whiska" => ^line}}, 1_000
    end
  end

  describe "a working mouse" do
    setup %{worktree: worktree} do
      stub(Herdr, :list_panes, fn @socket ->
        {:ok, [Map.put(pane(worktree, "working", "w2"), :title, "Order builder")]}
      end)

      stub(Herdr, :subscribe, fn @socket, _subs, _listener -> fake_subscription() end)
      :ok
    end

    test "turns its spinner a step every write, so a still one means the owl stopped", %{
      main: main,
      worktree: worktree
    } do
      fake_herdr([main_ws(main), mouse_ws("w2", worktree)])
      open(main, [])

      spun =
        for _ <- 1..3 do
          assert_receive {:reported, "w2", %{"whiska" => said}}, 1_000
          said
        end

      assert spun == ["◐ Order builder", "◓ Order builder", "◑ Order builder"]
    end
  end

  describe "the board under the lines" do
    test "is built from herdr less often than the lines are written", %{
      main: main,
      worktree: worktree
    } do
      asked = :counters.new(1, [])

      stub(Herdr, :list_panes, fn @socket ->
        :counters.add(asked, 1, 1)
        {:ok, [Map.put(pane(worktree, "working", "w2"), :title, "Orders")]}
      end)

      stub(Herdr, :subscribe, fn @socket, _subs, _listener -> fake_subscription() end)
      fake_herdr([main_ws(main), mouse_ws("w2", worktree)])

      house = open(main, board_ms: 60_000, panes_ms: 60_000)
      assert_receive {:reported, "w2", %{"whiska" => "◐ Orders"}}, 1_000
      before = :counters.get(asked, 1)

      send(house, :board)
      assert House.sync(house) == :ok

      assert_received {:reported, "w2", %{"whiska" => "◓ Orders"}}
      assert :counters.get(asked, 1) == before
    end

    test "carries an answer its mouse never took, which is the person's again", %{
      main: main,
      worktree: worktree
    } do
      {:ok, handle} = Storage.open(main, name: nil)

      {:ok, q} =
        Storage.record_question(%{mouse_id: "ma", text: "which?", kind: "needs-decision"})

      {:ok, _} = Storage.answer(q.id, "SQLite")
      {:ok, _} = Storage.mark_not_taken(q.id, DateTime.utc_now())
      Storage.close(handle)

      stub(Herdr, :list_panes, fn @socket -> {:ok, [pane(worktree, "idle", "w2")]} end)
      stub(Herdr, :subscribe, fn @socket, _subs, _listener -> fake_subscription() end)
      fake_herdr([main_ws(main), mouse_ws("w2", worktree)])

      open(main, [])

      said = "🐭 ##{q.id} · answer not taken"
      assert_receive {:reported, "w2", %{"whiska" => ^said}}, 1_000
    end
  end

  describe "a line that does not change" do
    setup %{worktree: worktree} do
      stub(Herdr, :list_panes, fn @socket -> {:ok, [pane(worktree, "unknown", "w2")]} end)
      stub(Herdr, :subscribe, fn @socket, _subs, _listener -> fake_subscription() end)
      :ok
    end

    test "is sent again before its TTL runs out, with that TTL", %{
      main: main,
      worktree: worktree
    } do
      test = self()
      held = fake_herdr([main_ws(main), mouse_ws("w2", worktree)])

      stub(Herdr, :report_metadata, fn @socket, ws, sent, ttl_ms ->
        Agent.update(held, &Map.put(&1, ws, Map.reject(sent, fn {_, v} -> is_nil(v) end)))
        send(test, {:reported, ws, sent, ttl_ms})
        :ok
      end)

      # herdr is read once, and holds the line from then on: nothing but the
      # refresh can send it again.
      open(main,
        board_ms: 20,
        panes_ms: 60_000,
        sidebar_ttl_ms: 1_000,
        sidebar_refresh_ms: 150
      )

      line = %{"whiska" => "? herdr can't say", "whiska_q" => nil, "whiska_q2" => nil}
      assert_receive {:reported, "w2", ^line, 1_000}, 1_000
      started = System.monotonic_time(:millisecond)

      assert_receive {:reported, "w2", ^line, 1_000}, 1_000
      waited = System.monotonic_time(:millisecond) - started

      assert waited >= 130, "sent again after #{waited} ms, before the refresh was due"
      assert waited < 1_000, "not sent again before the TTL ran out"
    end
  end

  describe "the order of the mice" do
    setup %{main: main} do
      worktree_b = Path.join([main, "worktrees", "feat-b"])
      File.mkdir_p!(worktree_b)

      {:ok, handle} = Storage.open(main, name: nil)
      :ok = Storage.set_main_pane("w1:p2")
      {:ok, _} = Storage.record_mouse(%{mouse_id: "mb", path: worktree_b, branch: "feat-b"})
      Storage.close(handle)

      stub(Herdr, :subscribe, fn @socket, _subs, _listener -> fake_subscription() end)

      stub(Herdr, :pane, fn @socket, "w1:p2" ->
        {:ok, %{pane_id: "w1:p2", cwd: main, agent: "claude", agent_status: "working"}}
      end)

      {:ok, worktree_b: worktree_b}
    end

    test "moves a mouse that starts needing the person above the rest, once", %{
      main: main,
      worktree: worktree,
      worktree_b: worktree_b
    } do
      stub(Herdr, :list_panes, fn @socket ->
        {:ok, [pane(worktree, "working", "w2"), pane(worktree_b, "idle", "w3")]}
      end)

      fake_herdr([
        main_ws(main),
        mouse_ws("w2", worktree),
        mouse_ws("w9", "/elsewhere"),
        mouse_ws("w3", worktree_b)
      ])

      house = open(main, [])

      # Nothing needs the person yet, and the working mouse already sits first.
      refute_receive {:moved, _, _}, 150

      in_house(house, fn ->
        {:ok, _} =
          Storage.record_question(%{mouse_id: "mb", text: "which db?", kind: "needs-decision"})
      end)

      # The block lands where its first member sat: before the first workspace
      # after it that is not one of the mice.
      assert_receive {:moved, ["w3", "w2"], "w9"}, 1_000

      # The set of mice needing the person has not changed since: no more moves.
      refute_receive {:moved, _, _}, 200
    end

    test "leaves the order alone when it is already right", %{
      main: main,
      worktree: worktree,
      worktree_b: worktree_b
    } do
      {:ok, handle} = Storage.open(main, name: nil)

      {:ok, _} =
        Storage.record_question(%{mouse_id: "ma", text: "which db?", kind: "needs-decision"})

      Storage.close(handle)

      stub(Herdr, :list_panes, fn @socket ->
        {:ok, [pane(worktree, "idle", "w2"), pane(worktree_b, "working", "w3")]}
      end)

      fake_herdr([main_ws(main), mouse_ws("w2", worktree), mouse_ws("w3", worktree_b)])
      open(main, [])

      assert_receive {:reported, "w2", _}, 1_000
      refute_receive {:moved, _, _}, 200
    end
  end

  describe "another repo" do
    test "keeps its lines: a house speaks only for its own workspaces", %{
      main: main,
      worktree: worktree
    } do
      stub(Herdr, :list_panes, fn @socket -> {:ok, [pane(worktree, "working", "w2")]} end)
      stub(Herdr, :subscribe, fn @socket, _subs, _listener -> fake_subscription() end)

      held =
        fake_herdr([
          main_ws(main),
          mouse_ws("w2", worktree),
          mouse_ws("w5", "/other/worktrees/x")
        ])

      Agent.update(held, &Map.put(&1, "w5", %{"whiska" => "🐭 #4 · waiting on you"}))

      open(main, [])

      assert_receive {:reported, "w2", _}, 1_000
      refute_receive {:reported, "w5", _}, 200
    end
  end

  describe "a mouse that stops having anything to say" do
    test "has its line cleared, not left to expire", %{main: main, worktree: worktree} do
      status = :counters.new(1, [])

      stub(Herdr, :list_panes, fn @socket ->
        said = if :counters.get(status, 1) == 0, do: "working", else: "idle"
        {:ok, [pane(worktree, said, "w2")]}
      end)

      stub(Herdr, :subscribe, fn @socket, _subs, _listener -> fake_subscription() end)
      fake_herdr([main_ws(main), mouse_ws("w2", worktree)])

      open(main, [])
      assert_receive {:reported, "w2", %{"whiska" => "◐" <> _}}, 1_000

      :counters.put(status, 1, 1)

      assert_receive {:reported, "w2", %{"whiska" => nil, "whiska_q" => nil, "whiska_q2" => nil}},
                     1_000
    end
  end

  describe "the main checkout's line" do
    setup %{worktree: worktree} do
      stub(Herdr, :list_panes, fn @socket -> {:ok, [pane(worktree, "working", "w2")]} end)
      stub(Herdr, :subscribe, fn @socket, _subs, _listener -> fake_subscription() end)
      :ok
    end

    test "says no main session is recorded", %{main: main, worktree: worktree} do
      fake_herdr([main_ws(main), mouse_ws("w2", worktree)])
      open(main, [])

      assert_receive {:reported, "w1", %{"whiska" => "✖ no main session: whiska start"}},
                     1_000
    end

    test "says nothing of a hold younger than its fuse (ADR-0082)", %{
      main: main,
      worktree: worktree
    } do
      {:ok, handle} = Storage.open(main, name: nil)
      :ok = Storage.set_main_pane("w1:p2")

      {:ok, _} =
        Storage.record_question(%{mouse_id: "ma", text: "which db?", kind: "needs-decision"})

      Storage.close(handle)

      stub(Herdr, :pane, fn @socket, "w1:p2" ->
        {:ok, %{pane_id: "w1:p2", cwd: main, agent: "claude", agent_status: "working"}}
      end)

      fake_herdr([main_ws(main), mouse_ws("w2", worktree)])
      house = open(main, hold_notice_ms: 60_000)

      assert_receive {:reported, "w2", _}, 1_000
      assert House.held(house) == :mid_turn
      refute_receive {:reported, "w1", _}, 300
    end

    test "says why nothing is delivered once a hold has lasted (ADR-0082)", %{
      main: main,
      worktree: worktree
    } do
      {:ok, handle} = Storage.open(main, name: nil)
      :ok = Storage.set_main_pane("w1:p2")

      {:ok, _} =
        Storage.record_question(%{mouse_id: "ma", text: "which db?", kind: "needs-decision"})

      Storage.close(handle)

      stub(Herdr, :pane, fn @socket, "w1:p2" ->
        {:ok, %{pane_id: "w1:p2", cwd: main, agent: "claude", agent_status: "working"}}
      end)

      fake_herdr([main_ws(main), mouse_ws("w2", worktree)])
      open(main, hold_notice_ms: 0)

      assert_receive {:reported, "w1", %{"whiska" => "⏳ gated: main is mid-turn"}},
                     1_000
    end
  end

  describe "a herdr that went away" do
    test "gets every line back as soon as it answers again", %{main: main, worktree: worktree} do
      down = :counters.new(1, [])
      test = self()

      stub(Herdr, :list_panes, fn @socket ->
        if :counters.get(down, 1) == 1,
          do: {:error, :econnrefused},
          else: {:ok, [Map.put(pane(worktree, "working", "w2"), :title, "Orders")]}
      end)

      stub(Herdr, :subscribe, fn @socket, _subs, _listener -> fake_subscription() end)
      held = fake_herdr([main_ws(main), mouse_ws("w2", worktree)])

      stub(Herdr, :report_metadata, fn @socket, ws, sent, _ttl ->
        if :counters.get(down, 1) == 1 do
          {:error, :econnrefused}
        else
          Agent.update(held, &Map.put(&1, ws, Map.reject(sent, fn {_, v} -> is_nil(v) end)))
          send(test, {:reported, ws, sent})
          :ok
        end
      end)

      open(main, [])
      assert_receive {:reported, "w2", _}, 1_000

      # herdr goes down, long enough for every send to fail, and comes back
      # having forgotten everything.
      :counters.put(down, 1, 1)
      ExUnit.CaptureIO.capture_io(:stderr, fn -> Process.sleep(150) end)
      Agent.update(held, fn _ -> %{} end)
      flush_reports()
      :counters.put(down, 1, 0)

      assert_receive {:reported, "w2", %{"whiska" => "◐" <> _}}, 500
    end
  end

  defp flush_refusals do
    receive do
      {:refused, _} -> flush_refusals()
    after
      0 -> :ok
    end
  end

  defp flush_reports do
    receive do
      {:reported, _, _} -> flush_reports()
    after
      0 -> :ok
    end
  end

  describe "a herdr that cannot draw the sidebar" do
    test "an older herdr refusing the call costs one warning, and one try per tick", %{
      main: main,
      worktree: worktree
    } do
      test = self()
      worktree_b = Path.join([main, "worktrees", "feat-b"])
      File.mkdir_p!(worktree_b)

      {:ok, handle} = Storage.open(main, name: nil)
      {:ok, _} = Storage.record_mouse(%{mouse_id: "mb", path: worktree_b, branch: "feat-b"})
      Storage.close(handle)

      stub(Herdr, :list_panes, fn @socket ->
        {:ok, [pane(worktree, "working", "w2"), pane(worktree_b, "working", "w3")]}
      end)

      stub(Herdr, :subscribe, fn @socket, _subs, _listener -> fake_subscription() end)
      fake_herdr([main_ws(main), mouse_ws("w2", worktree), mouse_ws("w3", worktree_b)])

      stub(Herdr, :report_metadata, fn @socket, ws, _tokens, _ttl ->
        send(test, {:refused, ws})
        {:error, {:herdr, %{"code" => "unknown_method"}}}
      end)

      warned =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          house = open(main, board_ms: 60_000, panes_ms: 0)

          for _tick <- 1..3 do
            flush_refusals()
            send(house, :board)
            assert House.sync(house) == :ok
            assert_received {:refused, _ws}
            refute_received {:refused, _ws}, "a second send in the same tick"
          end

          assert Process.alive?(house)
        end)

      assert warned |> String.split("herdr would not take a sidebar line") |> length() == 2
    end

    test "herdr failing mid-tick does not take the house down with it", %{
      main: main,
      worktree: worktree
    } do
      asked = :counters.new(1, [])

      stub(Herdr, :list_panes, fn @socket ->
        if :counters.get(asked, 1) == 1, do: raise("herdr blew up")
        {:ok, [pane(worktree, "working", "w2")]}
      end)

      stub(Herdr, :subscribe, fn @socket, _subs, _listener -> fake_subscription() end)
      fake_herdr([main_ws(main), mouse_ws("w2", worktree)])

      house = open(main, board_ms: 20)
      assert_receive {:reported, "w2", _}, 1_000

      :counters.put(asked, 1, 1)
      Process.sleep(60)
      :counters.put(asked, 1, 0)

      assert House.sync(house) == :ok
      assert Process.alive?(house)
    end
  end

  # Dropping a worktree closes its herdr workspace, and herdr reports that as
  # `workspace_closed` alone, with no `pane_closed` for the panes inside it.
  test "a closed workspace marks its mouse dead at once", %{main: main, worktree: worktree} do
    listed = :counters.new(1, [])

    stub(Herdr, :list_panes, fn @socket ->
      if :counters.get(listed, 1) == 0, do: {:ok, [pane(worktree, "idle", "w2")]}, else: {:ok, []}
    end)

    stub(Herdr, :subscribe, fn @socket, _subs, _listener -> fake_subscription() end)
    fake_herdr([main_ws(main)])

    house = open(main, board_ms: 60_000, panes_ms: 60_000)

    :counters.put(listed, 1, 1)
    send(house, {:herdr_event, "workspace_closed", %{"workspace_id" => "w2"}})
    assert House.sync(house) == :ok

    in_house(house, fn -> assert %DateTime{} = Storage.mouse("ma").died_at end)
  end

  test "clears the board files an older owl wrote for the statusline", %{
    main: main,
    worktree: worktree
  } do
    board = Path.join(Whiska.OpenHouses.home(), "board")
    File.mkdir_p!(board)
    File.write!(Path.join(board, "old-board"), "🐭 feat-a  working")

    stub(Herdr, :list_panes, fn @socket -> {:ok, [pane(worktree, "working", "w2")]} end)
    stub(Herdr, :subscribe, fn @socket, _subs, _listener -> fake_subscription() end)
    fake_herdr([main_ws(main), mouse_ws("w2", worktree)])

    open(main, [])

    refute File.exists?(board)
  end

  defp in_house(house, fun) do
    Storage.point_at(House.repo(house))
    fun.()
  end
end
