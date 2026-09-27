defmodule Whiska.Owl.HouseTest do
  @moduledoc """
  One open house: pane discovery, the herdr subscription, dead mice, and
  collection on every trigger ADR-0036 names.
  """
  use ExUnit.Case, async: false

  import Mox

  alias Whiska.Doorstep
  alias Whiska.Doorstep.Entry
  alias Whiska.Herdr.Mock, as: Herdr
  alias Whiska.Owl.House
  alias Whiska.Schema.Question
  alias Whiska.Storage

  setup :set_mox_global
  setup :verify_on_exit!

  @socket "/fake/herdr.sock"

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-house-#{System.unique_integer([:positive])}")
    main = Path.join(root, "myrepo")
    File.mkdir_p!(Path.join(main, ".git"))
    on_exit(fn -> File.rm_rf!(root) end)

    # Two mice on disk, recorded the way the hook records them: no pane yet.
    a = worktree(main, "feat-a")
    b = worktree(main, "feat-b")
    {:ok, handle} = Storage.open(main, name: :seed)
    {:ok, _} = Storage.record_mouse(%{mouse_id: "ma", path: a, branch: "feat-a"})
    {:ok, _} = Storage.record_mouse(%{mouse_id: "mb", path: b, branch: "feat-b"})
    Storage.close(handle)

    {:ok, main: main, a: a, b: b}
  end

  defp worktree(main, branch) do
    path = Path.join([main, "worktrees", branch])
    File.mkdir_p!(path)
    path
  end

  # A stand-in for the subscription process the real client would hold.
  defp fake_subscription do
    {:ok, spawn(fn -> receive do: (:stop -> :ok) end)}
  end

  defp panes(list), do: {:ok, list}

  defp pane(id, cwd, status \\ "working"),
    do: %{pane_id: id, cwd: cwd, agent: "claude", agent_status: status}

  defp open(main, opts \\ []) do
    {id, opts} = Keyword.pop(opts, :id, House)
    opts = Keyword.merge([main_checkout: main, herdr_socket: @socket, backstop_ms: 60_000], opts)
    pid = start_supervised!(Supervisor.child_spec({House, opts}, id: id))
    House.sync(pid)
    pid
  end

  defp in_house(house, fun) do
    Storage.point_at(House.repo(house))
    fun.()
  end

  defp leave(main, mouse_id, root, text) do
    {:ok, file} =
      Doorstep.leave(main, %Entry{
        mouse_id: mouse_id,
        branch: Path.basename(root),
        worktree_root: root,
        stamped_at: DateTime.utc_now(),
        text: text
      })

    file
  end

  describe "opening a house" do
    test "finds each mouse's pane by cwd and records it (ADR-0006)", %{main: main, a: a, b: b} do
      expect(Herdr, :list_panes, fn @socket ->
        panes([pane("w1:p1", a), pane("w2:p1", Path.join(b, "lib")), pane("w3:p1", "/elsewhere")])
      end)

      stub(Herdr, :subscribe, fn @socket, _subs, _listener -> fake_subscription() end)

      house = open(main)

      in_house(house, fn ->
        assert Storage.mouse("ma").pane == "w1:p1"
        # A session sitting in a subfolder of its worktree still belongs to it.
        assert Storage.mouse("mb").pane == "w2:p1"
      end)
    end

    test "subscribes to the global events and to status changes for each mouse pane", %{
      main: main,
      a: a
    } do
      stub(Herdr, :list_panes, fn @socket -> panes([pane("w1:p1", a)]) end)
      test = self()

      expect(Herdr, :subscribe, fn @socket, subs, listener ->
        send(test, {:subscribed, subs, listener})
        fake_subscription()
      end)

      house = open(main)

      assert_receive {:subscribed, subs, ^house}
      assert %{type: "pane.closed"} in subs
      assert %{type: "pane.exited"} in subs
      assert %{type: "pane.agent_detected"} in subs
      assert %{type: "pane.agent_status_changed", pane_id: "w1:p1"} in subs
      refute Enum.any?(subs, &match?(%{type: "pane.agent_status_changed", pane_id: "w2:p1"}, &1))
    end

    test "a mouse whose pane is nowhere to be found is marked dead (ADR-0026)", %{
      main: main,
      a: a
    } do
      stub(Herdr, :list_panes, fn @socket -> panes([pane("w1:p1", a)]) end)
      stub(Herdr, :subscribe, fn @socket, _, _ -> fake_subscription() end)

      house = open(main)

      in_house(house, fn ->
        assert is_nil(Storage.mouse("ma").died_at)
        assert %DateTime{} = Storage.mouse("mb").died_at
      end)
    end

    test "when herdr is unreachable the house still opens and nothing is marked dead", %{
      main: main
    } do
      stub(Herdr, :list_panes, fn @socket -> {:error, :econnrefused} end)
      stub(Herdr, :subscribe, fn @socket, _, _ -> {:error, :econnrefused} end)

      house = open(main)

      in_house(house, fn ->
        assert is_nil(Storage.mouse("ma").died_at)
        assert is_nil(Storage.mouse("mb").died_at)
      end)
    end

    test "collects whatever landed while the owl was down", %{main: main, a: a} do
      stub(Herdr, :list_panes, fn @socket -> panes([pane("w1:p1", a)]) end)
      stub(Herdr, :subscribe, fn @socket, _, _ -> fake_subscription() end)
      file = leave(main, "ma", a, "Which db?\n[worktree-status: needs-decision] pick")

      house = open(main)
      House.collect(house)

      assert Doorstep.waiting(main) == []
      assert File.exists?(file <> ".collected")

      in_house(house, fn ->
        assert [%Question{mouse_id: "ma", kind: "needs-decision", status: "open"} = q] =
                 Storage.all(Question)

        assert q.text =~ "Which db?"
      end)
    end
  end

  describe "collection" do
    setup %{main: main, a: a} do
      stub(Herdr, :list_panes, fn @socket -> panes([pane("w1:p1", a)]) end)
      stub(Herdr, :subscribe, fn @socket, _, _ -> fake_subscription() end)
      {:ok, house: open(main)}
    end

    test "happens when herdr reports the mouse's pane idle", %{main: main, a: a, house: house} do
      leave(main, "ma", a, "[worktree-status: needs-decision] which one?")

      send(
        house,
        {:herdr_event, "pane_agent_status_changed",
         %{"pane_id" => "w1:p1", "agent_status" => "idle"}}
      )

      House.sync(house)

      assert Doorstep.waiting(main) == []
      in_house(house, fn -> assert [%Question{status: "open"}] = Storage.all(Question) end)
    end

    test "does not happen on working, blocked, or a pane that is not a mouse", %{
      main: main,
      a: a,
      house: house
    } do
      leave(main, "ma", a, "[worktree-status: needs-decision] which one?")

      send(
        house,
        {:herdr_event, "pane_agent_status_changed",
         %{"pane_id" => "w1:p1", "agent_status" => "working"}}
      )

      send(
        house,
        {:herdr_event, "pane_agent_status_changed",
         %{"pane_id" => "w1:p1", "agent_status" => "blocked"}}
      )

      send(
        house,
        {:herdr_event, "pane_agent_status_changed",
         %{"pane_id" => "w9:p9", "agent_status" => "idle"}}
      )

      House.sync(house)

      assert length(Doorstep.waiting(main)) == 1
    end

    test "a done report is left open to be delivered, like any other (ADR-0009)", %{
      main: main,
      a: a,
      house: house
    } do
      leave(main, "ma", a, "Merged.\n[worktree-status: done]")
      House.collect(house)

      in_house(house, fn ->
        assert [%Question{kind: "done", status: "open"}] = Storage.all(Question)
      end)
    end

    test "no marker at all is recorded as unmarked and left open to be delivered (ADR-0009)", %{
      main: main,
      a: a,
      house: house
    } do
      leave(main, "ma", a, "I stopped for some reason.")
      House.collect(house)

      in_house(house, fn ->
        assert [%Question{kind: "unmarked", status: "open"}] = Storage.all(Question)
      end)
    end

    test "an entry whose worktree is gone is recorded but orphaned, never delivered (ADR-0036)",
         %{main: main, house: house} do
      gone = Path.join([main, "worktrees", "feat-gone"])
      leave(main, "ma", gone, "[worktree-status: needs-decision] anyone?")
      House.collect(house)

      in_house(house, fn -> assert [%Question{status: "orphaned"}] = Storage.all(Question) end)
    end

    test "an entry from a mouse the house has never seen records that mouse first", %{
      main: main,
      house: house
    } do
      new = worktree(main, "feat-new")
      leave(main, "mnew", new, "[worktree-status: needs-decision] hello?")
      House.collect(house)

      in_house(house, fn ->
        assert Storage.mouse("mnew").branch == "feat-new"
        assert [%Question{mouse_id: "mnew", status: "open"}] = Storage.all(Question)
      end)
    end

    test "reports how many it collected", %{main: main, a: a, house: house} do
      leave(main, "ma", a, "[worktree-status: done]")
      leave(main, "ma", a, "[worktree-status: done]")

      assert {:ok, 2} = House.collect(house)
      assert {:ok, 0} = House.collect(house)
    end

    test "the backstop timer collects on its own", %{main: main, a: a} do
      house = open(main, backstop_ms: 50, id: :second_house)
      leave(main, "ma", a, "[worktree-status: done]")

      Process.sleep(150)
      House.sync(house)

      assert Doorstep.waiting(main) == []
    end
  end

  describe "dead mice (ADR-0026)" do
    setup %{main: main, a: a, b: b} do
      stub(Herdr, :list_panes, fn @socket -> panes([pane("w1:p1", a), pane("w2:p1", b)]) end)
      stub(Herdr, :subscribe, fn @socket, _, _ -> fake_subscription() end)
      {:ok, house: open(main)}
    end

    test "a closed pane marks its mouse dead and orphans its open questions", %{
      main: main,
      a: a,
      house: house
    } do
      leave(main, "ma", a, "[worktree-status: needs-decision] ?")
      House.collect(house)

      send(house, {:herdr_event, "pane_closed", %{"pane_id" => "w1:p1"}})
      House.sync(house)

      in_house(house, fn ->
        assert %DateTime{} = Storage.mouse("ma").died_at
        assert is_nil(Storage.mouse("mb").died_at)
        assert [%Question{status: "orphaned"}] = Storage.all(Question)
      end)
    end

    test "an exited pane does the same", %{house: house} do
      send(house, {:herdr_event, "pane_exited", %{"pane_id" => "w2:p1"}})
      House.sync(house)

      in_house(house, fn -> assert %DateTime{} = Storage.mouse("mb").died_at end)
    end

    test "a pane that is not a mouse is ignored", %{house: house} do
      send(house, {:herdr_event, "pane_closed", %{"pane_id" => "w9:p9"}})
      House.sync(house)

      in_house(house, fn ->
        assert is_nil(Storage.mouse("ma").died_at)
        assert is_nil(Storage.mouse("mb").died_at)
      end)
    end
  end

  describe "the subscription" do
    test "is refreshed when a new agent pane appears, so the new mouse is watched too", %{
      main: main,
      a: a,
      b: b
    } do
      test = self()

      Herdr
      |> expect(:list_panes, fn @socket -> panes([pane("w1:p1", a)]) end)
      |> expect(:list_panes, fn @socket -> panes([pane("w1:p1", a), pane("w2:p1", b)]) end)

      stub(Herdr, :subscribe, fn @socket, subs, _ ->
        send(test, {:subscribed, subs})
        fake_subscription()
      end)

      house = open(main)
      assert_receive {:subscribed, first}
      refute %{type: "pane.agent_status_changed", pane_id: "w2:p1"} in first

      send(
        house,
        {:herdr_event, "pane_agent_detected", %{"pane_id" => "w2:p1", "agent" => "claude"}}
      )

      House.sync(house)

      assert_receive {:subscribed, second}
      assert %{type: "pane.agent_status_changed", pane_id: "w2:p1"} in second
      in_house(house, fn -> assert Storage.mouse("mb").pane == "w2:p1" end)
    end

    test "is reopened when herdr drops it", %{main: main, a: a} do
      test = self()
      stub(Herdr, :list_panes, fn @socket -> panes([pane("w1:p1", a)]) end)

      stub(Herdr, :subscribe, fn @socket, _, _ ->
        send(test, :subscribed)
        fake_subscription()
      end)

      house = open(main, resubscribe_ms: 20)
      assert_receive :subscribed

      send(house, {:herdr_subscription_lost, :closed})
      assert_receive :subscribed, 500
    end

    test "keeps trying while herdr is down", %{main: main, a: a} do
      test = self()
      stub(Herdr, :list_panes, fn @socket -> panes([pane("w1:p1", a)]) end)

      Herdr
      |> expect(:subscribe, fn @socket, _, _ -> {:error, :econnrefused} end)
      |> expect(:subscribe, fn @socket, _, _ ->
        send(test, :subscribed)
        fake_subscription()
      end)

      open(main, resubscribe_ms: 20)
      assert_receive :subscribed, 500
    end
  end

  describe "shutting the house" do
    test "closes the database and drops the subscription; the house stays on disk", %{
      main: main,
      a: a
    } do
      stub(Herdr, :list_panes, fn @socket -> panes([pane("w1:p1", a)]) end)
      {:ok, sub} = fake_subscription()
      stub(Herdr, :subscribe, fn @socket, _, _ -> {:ok, sub} end)

      house = open(main)
      repo = House.repo(house)
      ref = Process.monitor(sub)

      :ok = stop_supervised!(House)

      refute Process.alive?(repo)
      assert_receive {:DOWN, ^ref, :process, ^sub, _}
      assert File.exists?(Storage.database_path(main))
    end
  end
end
