defmodule Whiska.Owl.HouseTest do
  @moduledoc """
  One open house: pane discovery, the herdr subscription, dead mice, and
  collection on every trigger ADR-0036 names.
  """
  # Serial: the retry and backstop tests race real timers tens of ms apart, and a
  # loaded parallel run fires them late.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import Mox

  alias Whiska.Backstop
  alias Whiska.Doorstep
  alias Whiska.Doorstep.Entry
  alias Whiska.Herdr.Mock, as: Herdr
  alias Whiska.Owl.House
  alias Whiska.Schema.Question
  alias Whiska.Storage
  alias Whiska.Research

  setup :verify_on_exit!
  setup {Whiska.Test.QuietSidebar, :stub_sidebar}

  @socket "/fake/herdr.sock"

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-house-#{System.unique_integer([:positive])}")
    main = Path.join(root, "myrepo")
    File.mkdir_p!(Path.join(main, ".git"))
    on_exit(fn -> File.rm_rf!(root) end)

    # Two mice on disk, recorded the way the hook records them: no pane yet.
    a = worktree(main, "feat-a")
    b = worktree(main, "feat-b")
    {:ok, handle} = Storage.open(main, name: nil)
    {:ok, _} = Storage.record_mouse(%{mouse_id: "ma", path: a, branch: "feat-a"})
    {:ok, _} = Storage.record_mouse(%{mouse_id: "mb", path: b, branch: "feat-b"})
    Storage.close(handle)

    {:ok, main: main, a: a, b: b}
  end

  # The house calls herdr from its own process, from `init/1` on, so it is
  # allowed in by name before it starts.
  defp start_house(opts, id) do
    name = :"house-#{System.unique_integer([:positive])}"
    allow(Herdr, self(), fn -> Process.whereis(name) end)
    start_supervised!(Supervisor.child_spec({House, [name: name] ++ opts}, id: id))
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

    opts =
      Keyword.merge(
        [main_checkout: main, herdr_socket: @socket, backstop_ms: 60_000, board_ms: 60_000],
        opts
      )

    pid = start_house(opts, id)
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

  defp leave_spec(main, mouse_id, root, stamped_at, spec, branch \\ nil) do
    {:ok, file} =
      Doorstep.leave(main, %Entry{
        mouse_id: mouse_id,
        branch: branch || Path.basename(root),
        worktree_root: root,
        stamped_at: stamped_at,
        text: "ok to build?",
        spec: spec
      })

    file
  end

  describe "opening a house" do
    test "finds each mouse's pane by cwd and records it (ADR-0028)", %{main: main, a: a, b: b} do
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

    test "hides a research document from git in every worktree, as it hides the marker", %{
      main: main
    } do
      stub(Herdr, :list_panes, fn @socket -> panes([]) end)
      stub(Herdr, :subscribe, fn @socket, _subs, _listener -> fake_subscription() end)

      open(main)

      lines = main |> Path.join(".git/info/exclude") |> File.read!() |> String.split("\n")
      assert Whiska.Marker.exclude_line() in lines
      assert Research.exclude_line() in lines
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
      assert %{type: "workspace.closed"} in subs
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

    # The record for `feat` is what a slashed branch left behind before ADR-0030's
    # note: `worktrees/feat` is an ordinary directory holding `feat/checkout-form`,
    # so every pane of the real mouse sits inside it. Matching it kept clearing
    # its `died_at`, and the board carried a branch that no longer existed.
    test "a stale record is not revived by the mouse nested inside its folder", %{main: main} do
      nested = worktree(main, "feat/checkout-form")
      stale = Path.join([main, "worktrees", "feat"])

      {:ok, handle} = Storage.open(main, name: nil)
      {:ok, _} = Storage.record_mouse(%{mouse_id: "mstale", path: stale, branch: "feat"})

      {:ok, _} =
        Storage.record_mouse(%{
          mouse_id: "mnested",
          path: nested,
          branch: "feat/checkout-form"
        })

      Storage.close(handle)

      stub(Herdr, :list_panes, fn @socket -> panes([pane("w9:p1", nested)]) end)
      stub(Herdr, :subscribe, fn @socket, _, _ -> fake_subscription() end)

      house = open(main, id: :stale_house)

      in_house(house, fn ->
        assert Storage.mouse("mnested").pane == "w9:p1"
        assert is_nil(Storage.mouse("mnested").died_at)
        assert is_nil(Storage.mouse("mstale").pane)
        assert %DateTime{} = Storage.mouse("mstale").died_at
        assert "mstale" not in Enum.map(Storage.alive_mice(), & &1.mouse_id)
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

    test "a revised spec overwrites its saved copy and names the question it replaced", %{
      main: main,
      a: a,
      house: house
    } do
      leave_spec(main, "ma", a, ~U[2026-10-06 09:00:00Z], "# Spec\n\nfirst\n")
      House.collect(house)
      leave_spec(main, "ma", a, ~U[2026-10-07 09:00:00Z], "# Spec\n\nsecond\n")
      House.collect(house)

      [first, second] = in_house(house, fn -> Enum.sort_by(Storage.all(Question), & &1.id) end)

      assert [file] = Path.wildcard(Path.join(main, ".whiska/specs/*.md"))
      assert Path.basename(file) == "2026-10-06-feat-a.md"
      saved = File.read!(file)
      assert saved =~ "second"
      refute saved =~ "first"
      assert saved =~ "repo: myrepo\n"
      assert saved =~ "branch: feat-a\n"
      assert saved =~ "question: #{second.id}\n"
      assert saved =~ "replaced: #{first.id}\n"
      assert saved =~ "status: waiting\n"
      assert first.spec_sent and second.spec_sent

      exclude = File.read!(Path.join(main, ".git/info/exclude"))
      assert exclude |> String.split("\n") |> Enum.count(&(&1 == "/.whiska/")) == 1
    end

    test "a later turn that leaves the spec unchanged does not move it", %{
      main: main,
      a: a,
      house: house
    } do
      leave_spec(main, "ma", a, ~U[2026-10-06 09:00:00Z], "# Spec\n")
      House.collect(house)
      leave_spec(main, "ma", a, ~U[2026-10-06 10:00:00Z], "# Spec\n")
      House.collect(house)

      [first, again] = in_house(house, fn -> Enum.sort_by(Storage.all(Question), & &1.id) end)
      [file] = Path.wildcard(Path.join(main, ".whiska/specs/*.md"))
      assert File.read!(file) =~ "question: #{first.id}\n"
      refute File.read!(file) =~ "replaced:"
      assert first.spec_sent
      refute again.spec_sent
    end

    test "a build plan is kept beside its spec, and alone never counts as a spec sent", %{
      main: main,
      a: a,
      house: house
    } do
      leave_plan = fn stamped_at, plan ->
        {:ok, _} =
          Doorstep.leave(main, %Entry{
            mouse_id: "ma",
            branch: "feat-a",
            worktree_root: a,
            stamped_at: stamped_at,
            text: "ok to build?\n⁣⁣",
            spec: "# Spec\n",
            plan: plan
          })

        House.collect(house)
      end

      leave_plan.(~U[2026-10-06 09:00:00Z], "# Build plan\n\nfirst\n")
      leave_plan.(~U[2026-10-06 10:00:00Z], "# Build plan\n\nsecond\n")

      [first, second] = in_house(house, fn -> Enum.sort_by(Storage.all(Question), & &1.id) end)

      names = Enum.map(Path.wildcard(Path.join(main, ".whiska/specs/*.md")), &Path.basename/1)
      assert Enum.sort(names) == ["2026-10-06-feat-a.md", "2026-10-06-feat-a.plan.md"]

      plan = File.read!(Path.join(main, ".whiska/specs/2026-10-06-feat-a.plan.md"))
      assert plan =~ "second"
      assert plan =~ "question: #{second.id}\n"
      assert plan =~ "replaced: #{first.id}\n"
      assert plan =~ "status: waiting\n"
      assert File.read!(Path.join(main, ".whiska/specs/2026-10-06-feat-a.md")) =~ "# Spec\n"

      assert first.spec_sent
      refute second.spec_sent
    end

    test "hides a build plan from git when it opens, as it hides the research document", %{
      main: main
    } do
      lines = main |> Path.join(".git/info/exclude") |> File.read!() |> String.split("\n")
      assert Whiska.BuildPlan.exclude_line() in lines
    end

    test "a research document is kept per question, and is never taken for a spec", %{
      main: main,
      a: a,
      house: house
    } do
      {:ok, _} =
        Doorstep.leave(main, %Entry{
          mouse_id: "ma",
          branch: "feat-a",
          worktree_root: a,
          stamped_at: ~U[2026-10-06 09:00:00Z],
          text: "Found it.\n⁣⁣⁣",
          research: "# Why it hangs\n\nFound.\n"
        })

      House.collect(house)

      [q] = in_house(house, fn -> Storage.all(Question) end)
      assert File.read!(Research.kept(main, q.id)) == "# Why it hangs\n\nFound.\n"
      refute q.spec_sent
      assert Path.wildcard(Path.join(main, ".whiska/specs/*")) == []

      exclude = File.read!(Path.join(main, ".git/info/exclude"))
      assert "/.whiska/" in String.split(exclude, "\n")
    end

    test "a research document is kept for every question that carried one, finished or not", %{
      main: main,
      a: a,
      house: house
    } do
      {:ok, _} =
        Doorstep.leave(main, %Entry{
          mouse_id: "ma",
          branch: "feat-a",
          worktree_root: a,
          stamped_at: ~U[2026-10-06 09:00:00Z],
          text: "Which source?\n⁣⁣",
          research: "# Draft\n"
        })

      House.collect(house)

      [q] = in_house(house, fn -> Storage.all(Question) end)
      assert q.kind == "needs-decision"
      assert File.read!(Research.kept(main, q.id)) == "# Draft\n"
    end

    test "a turn with no spec keeps nothing and ignores nothing", %{
      main: main,
      a: a,
      house: house
    } do
      leave(main, "ma", a, "[worktree-status: needs-decision] which one?")
      House.collect(house)

      refute File.exists?(Path.join(main, ".whiska"))
      refute File.read!(Path.join(main, ".git/info/exclude")) =~ "/.whiska/"
    end

    test "a spec that cannot be kept still lets its question be collected", %{
      main: main,
      a: a,
      house: house
    } do
      File.write!(Path.join(main, ".whiska"), "a file where the folder would go")
      leave_spec(main, "ma", a, ~U[2026-10-06 09:00:00Z], "# Spec\n")

      capture_io(:stderr, fn -> House.collect(house) end)

      assert Doorstep.waiting(main) == []
      in_house(house, fn -> assert [%Question{}] = Storage.all(Question) end)
    end

    test "two mice on one branch name, the same day, keep two files", %{
      main: main,
      a: a,
      b: b,
      house: house
    } do
      leave_spec(main, "ma", a, ~U[2026-10-06 09:00:00Z], "# A\n", "feat/x")
      leave_spec(main, "mb", b, ~U[2026-10-06 09:30:00Z], "# B\n", "feat/x")
      House.collect(house)

      names = Enum.map(Path.wildcard(Path.join(main, ".whiska/specs/*.md")), &Path.basename/1)
      assert Enum.sort(names) == ["2026-10-06-feat-x-2.md", "2026-10-06-feat-x.md"]
    end

    # herdr 0.8.2 streams a per-pane subscription event under its subscription
    # type, `pane.agent_status_changed` (dot), and a mouse ending a turn in an
    # unfocused tab reports `done`, not `idle` — checked against the live socket
    # on 2026-09-28. Both spellings and both statuses have to trigger.
    test "happens when herdr reports the mouse's pane done", %{main: main, a: a, house: house} do
      leave(main, "ma", a, "[worktree-status: needs-decision] which one?")

      send(
        house,
        {:herdr_event, "pane.agent_status_changed",
         %{"pane_id" => "w1:p1", "agent_status" => "done"}}
      )

      House.sync(house)

      assert Doorstep.waiting(main) == []
      in_house(house, fn -> assert [%Question{status: "open"}] = Storage.all(Question) end)
    end

    test "happens when herdr reports the mouse's pane idle", %{main: main, a: a, house: house} do
      leave(main, "ma", a, "[worktree-status: needs-decision] which one?")

      send(
        house,
        {:herdr_event, "pane.agent_status_changed",
         %{"pane_id" => "w1:p1", "agent_status" => "idle"}}
      )

      House.sync(house)

      assert Doorstep.waiting(main) == []
    end

    test "still happens under the underscore spelling herdr's schema gives the event", %{
      main: main,
      a: a,
      house: house
    } do
      leave(main, "ma", a, "[worktree-status: needs-decision] which one?")

      send(
        house,
        {:herdr_event, "pane_agent_status_changed",
         %{"pane_id" => "w1:p1", "agent_status" => "done"}}
      )

      House.sync(house)

      assert Doorstep.waiting(main) == []
    end

    test "does not happen on working, blocked, or a pane that is not a mouse", %{
      main: main,
      a: a,
      house: house
    } do
      leave(main, "ma", a, "[worktree-status: needs-decision] which one?")

      send(
        house,
        {:herdr_event, "pane.agent_status_changed",
         %{"pane_id" => "w1:p1", "agent_status" => "working"}}
      )

      send(
        house,
        {:herdr_event, "pane.agent_status_changed",
         %{"pane_id" => "w1:p1", "agent_status" => "blocked"}}
      )

      send(
        house,
        {:herdr_event, "pane.agent_status_changed",
         %{"pane_id" => "w9:p9", "agent_status" => "done"}}
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

    test "an entry whose worktree is gone but whose branch landed arrives settled (ADR-0064)",
         %{main: main, house: house} do
      gone = Path.join([main, "worktrees", "feat-gone"])

      in_house(house, fn ->
        {:ok, _} =
          Storage.record_mouse(%{mouse_id: "ma", path: gone, branch: "feat-gone"})

        {:ok, _} = Storage.mark_landed("ma")
      end)

      leave(main, "ma", gone, "[worktree-status: needs-decision] anyone?")
      House.collect(house)

      in_house(house, fn -> assert [%Question{status: "settled"}] = Storage.all(Question) end)
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

    test "records the model the mouse's turn actually ran on", %{
      main: main,
      a: a,
      house: house
    } do
      {:ok, _} =
        Doorstep.leave(main, %Entry{
          mouse_id: "ma",
          branch: "feat-a",
          worktree_root: a,
          stamped_at: DateTime.utc_now(),
          text: "[worktree-status: done]",
          ran_on: "claude-a-5"
        })

      House.collect(house)

      in_house(house, fn -> assert Storage.mouse("ma").ran_on == "claude-a-5" end)
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

    # A mouse ending its turn, as herdr actually reports it (see above).
    defp idle(house, pane_id \\ "w1:p1") do
      send(
        house,
        {:herdr_event, "pane.agent_status_changed",
         %{"pane_id" => pane_id, "agent_status" => "done"}}
      )

      House.sync(house)
    end

    defp retry_timer(house), do: :sys.get_state(house).retry_timer

    # The two Stop hooks race (ADR-0036): herdr's idle event can reach the owl
    # before Whiska's hook has finished writing the entry.
    test "an entry written just after the idle event is collected on a retry, not the backstop",
         %{main: main, a: a} do
      house = open(main, backstop_ms: 60_000, retry_ms: [30, 100], id: :retry_house)

      idle(house)
      assert Doorstep.waiting(main) == []
      leave(main, "ma", a, "Merged.\n[worktree-status: done]")

      Process.sleep(80)
      House.sync(house)

      assert Doorstep.waiting(main) == []
      in_house(house, fn -> assert [%Question{kind: "done"}] = Storage.all(Question) end)
    end

    test "the second retry catches what the first one missed", %{main: main, a: a} do
      house = open(main, backstop_ms: 60_000, retry_ms: [30, 60], id: :retry_house)

      idle(house)
      Process.sleep(45)
      leave(main, "ma", a, "[worktree-status: done]")

      Process.sleep(80)
      House.sync(house)

      assert Doorstep.waiting(main) == []
    end

    test "retries stop as soon as a collection finds something", %{main: main, a: a} do
      house = open(main, backstop_ms: 60_000, retry_ms: [30, 60_000], id: :retry_house)

      idle(house)
      assert retry_timer(house) != nil
      leave(main, "ma", a, "[worktree-status: done]")

      Process.sleep(60)
      House.sync(house)

      assert Doorstep.waiting(main) == []
      assert retry_timer(house) == nil
    end

    test "an idle event that finds something never schedules a retry", %{main: main, a: a} do
      house = open(main, backstop_ms: 60_000, retry_ms: [60_000], id: :retry_house)
      leave(main, "ma", a, "[worktree-status: done]")

      idle(house)

      assert Doorstep.waiting(main) == []
      assert retry_timer(house) == nil
    end

    test "a second idle event while a retry is pending does not pile up timers", %{main: main} do
      house = open(main, backstop_ms: 60_000, retry_ms: [60_000, 60_000], id: :retry_house)

      idle(house)
      first = retry_timer(house)
      assert first != nil

      idle(house)
      assert retry_timer(house) == first
    end

    test "the retry delays run out without finding anything, and the house is left clean",
         %{main: main} do
      house = open(main, backstop_ms: 60_000, retry_ms: [20, 20], id: :retry_house)

      idle(house)
      Process.sleep(100)
      House.sync(house)

      assert retry_timer(house) == nil
    end
  end

  # The owl reads each turn's usage from the transcript the entry names, at
  # collection (ADR-0086). The shapes are the
  # ledger's own: one entry per content block repeating its message's usage,
  # and the effort on every assistant entry.
  describe "usage at collection" do
    setup %{main: main, a: a} do
      stub(Herdr, :list_panes, fn @socket -> panes([pane("w1:p1", a)]) end)
      stub(Herdr, :subscribe, fn @socket, _, _ -> fake_subscription() end)
      transcript = Path.join([main, "..", "projects", "wt", "s1.jsonl"]) |> Path.expand()
      File.mkdir_p!(Path.join(Path.rootname(transcript), "subagents"))
      {:ok, house: open(main), transcript: transcript}
    end

    defp usage(i, cw, cr, o),
      do: %{
        "input_tokens" => i,
        "cache_creation_input_tokens" => cw,
        "cache_read_input_tokens" => cr,
        "output_tokens" => o
      }

    defp call(id, at, usage, blocks, stop \\ "end_turn") do
      for block <- blocks do
        %{
          "type" => "assistant",
          "timestamp" => at,
          "effort" => "xhigh",
          "message" => %{
            "id" => id,
            "model" => "claude-opus-5-5",
            "stop_reason" => stop,
            "usage" => usage,
            "content" => [block]
          }
        }
      end
    end

    defp prompt(at),
      do: [%{"type" => "user", "timestamp" => at, "origin" => %{"kind" => "human"}}]

    defp api_error(at),
      do: [
        %{
          "type" => "assistant",
          "timestamp" => at,
          "isApiErrorMessage" => true,
          "message" => %{"id" => "e1", "model" => "<synthetic>", "usage" => usage(0, 0, 0, 0)}
        }
      ]

    defp text, do: %{"type" => "text", "text" => "…"}
    defp tool(id), do: %{"type" => "tool_use", "id" => id, "name" => "Bash", "input" => %{}}

    defp write_jsonl(path, entries) do
      File.write!(path, entries |> List.flatten() |> Enum.map_join("\n", &JSON.encode!/1))
    end

    defp agent(transcript, name, meta, entries) do
      dir = Path.join(Path.rootname(transcript), "subagents")
      write_jsonl(Path.join(dir, name <> ".jsonl"), entries)
      File.write!(Path.join(dir, name <> ".meta.json"), JSON.encode!(meta))
    end

    defp leave_turn(main, root, stamped_at, transcript) do
      {:ok, file} =
        Doorstep.leave(main, %Entry{
          mouse_id: "ma",
          branch: Path.basename(root),
          worktree_root: root,
          stamped_at: stamped_at,
          text: "[worktree-status: needs-decision] which one?",
          transcript: transcript
        })

      file
    end

    test "a collected entry naming its transcript leaves this turn's rows, cut at its stamp", %{
      main: main,
      a: a,
      house: house,
      transcript: transcript
    } do
      write_jsonl(transcript, [
        prompt("2026-10-11T09:00:00.000Z"),
        call("m1", "2026-10-11T09:00:05.000Z", usage(10, 100, 1000, 50), [text()]),
        # This turn: from the prompt that started it to the stop.
        prompt("2026-10-11T09:10:00.000Z"),
        call("m2", "2026-10-11T09:10:05.000Z", usage(5, 200, 3000, 40), [tool("t1"), text()]),
        api_error("2026-10-11T09:11:00.000Z"),
        call("m3", "2026-10-11T09:12:00.000Z", usage(1, 10, 3200, 20), [text()]),
        # The next turn, written before a late collection reads the file.
        prompt("2026-10-11T09:30:00.000Z"),
        call("m4", "2026-10-11T09:30:05.000Z", usage(999, 999, 999, 999), [text()])
      ])

      agent(transcript, "agent-old", %{"agentType" => "Explore", "description" => "Earlier"}, [
        call("o1", "2026-10-11T09:01:00.000Z", usage(9, 9, 9, 9), [text()])
      ])

      agent(
        transcript,
        "agent-a1",
        %{"agentType" => "general-purpose", "description" => "Security review"},
        [
          call("a1", "2026-10-11T09:10:30.000Z", usage(3, 300, 600, 30), [text()]),
          call("a2", "2026-10-11T09:11:30.000Z", usage(0, 0, 700, 5), [text()]),
          call("a3", "2026-10-11T09:20:00.000Z", usage(999, 999, 999, 999), [text()])
        ]
      )

      agent(transcript, "agent-next", %{"agentType" => "Explore", "description" => "Next"}, [
        call("n1", "2026-10-11T09:30:30.000Z", usage(9, 9, 9, 9), [text()])
      ])

      leave_turn(main, a, ~U[2026-10-11 09:15:00Z], transcript)
      House.collect(house)

      in_house(house, fn ->
        [question] = Storage.all(Question)
        rows = Storage.usage(question.id)

        assert [agent] = Enum.filter(rows, &(&1.scope == "agent"))
        assert [mouse] = Enum.filter(rows, &(&1.scope == "mouse"))

        assert %{
                 label: "Security review",
                 type: "general-purpose",
                 model: "claude-opus-5-5",
                 effort: "xhigh",
                 input: 3,
                 cache_writes: 300,
                 cache_reads: 1300,
                 output: 35,
                 steps: 2,
                 seconds: 60,
                 floor: false,
                 api_errors: 0
               } = agent

        assert %{
                 model: "claude-opus-5-5",
                 effort: "xhigh",
                 input: 6,
                 cache_writes: 210,
                 cache_reads: 6200,
                 output: 60,
                 steps: 2,
                 tool_uses: 1,
                 seconds: 120,
                 floor: false,
                 api_errors: 1
               } = mouse
      end)
    end

    # The escript writes a second entry for a turn the owl already wrote
    # (ADR-0036), and a session woken by a background task stops again with no
    # prompt in between. Both name the same turn.
    test "a second entry for the same turn replaces the first's rows, so rows still add up", %{
      main: main,
      a: a,
      house: house,
      transcript: transcript
    } do
      write_jsonl(transcript, [
        prompt("2026-10-11T09:10:00.000Z"),
        call("m1", "2026-10-11T09:10:05.000Z", usage(5, 0, 0, 0), [text()]),
        call("m2", "2026-10-11T09:12:00.000Z", usage(7, 0, 0, 0), [text()])
      ])

      leave_turn(main, a, ~U[2026-10-11 09:11:00Z], transcript)
      House.collect(house)
      leave_turn(main, a, ~U[2026-10-11 09:13:00Z], transcript)
      House.collect(house)

      in_house(house, fn ->
        [first, second] = Enum.sort_by(Storage.all(Question), & &1.id)

        assert [%{replaced: true, input: 5}] = Storage.usage(first.id)
        assert [%{replaced: false, input: 12, steps: 2}] = Storage.usage(second.id)
      end)
    end

    test "an entry naming no transcript, or one that is not there, is collected with no rows",
         %{main: main, a: a, house: house, transcript: transcript} do
      leave_turn(main, a, ~U[2026-10-11 09:15:00Z], nil)
      leave_turn(main, a, ~U[2026-10-11 09:16:00Z], transcript)
      House.collect(house)

      assert Doorstep.waiting(main) == []

      in_house(house, fn ->
        questions = Storage.all(Question)
        assert length(questions) == 2
        assert Enum.flat_map(questions, &Storage.usage(&1.id)) == []
      end)
    end
  end

  # A mouse's first question reaches the owl before any pane matching has seen
  # that mouse: the entry itself is what records it, and until 2026-09-28 the
  # mouse's `pane` column stayed nil until the backstop's minute was up. In that
  # minute `whiska waiting` said "no pane" and `whiska reply` refused, for a
  # mouse sitting right there in herdr.
  describe "matching a mouse to its pane on collection" do
    setup do
      stub(Herdr, :subscribe, fn @socket, _, _ -> fake_subscription() end)
      :ok
    end

    test "a never-seen mouse has its pane right after its first entry is collected",
         %{main: main, a: a} do
      new = worktree(main, "feat-new")
      stub(Herdr, :list_panes, fn @socket -> panes([pane("w1:p1", a), pane("w3:p1", new)]) end)

      house = open(main, backstop_ms: 60_000, id: :match_house)
      leave(main, "mnew", new, "[worktree-status: needs-decision] hello?")

      # The idle trigger, not the backstop: no timer is waited for here.
      idle(house)

      in_house(house, fn ->
        assert Storage.mouse("mnew").pane == "w3:p1"
        assert is_nil(Storage.mouse("mnew").died_at)
      end)
    end

    test "and is subscribed to, so its next turn triggers a collection of its own",
         %{main: main, a: a} do
      new = worktree(main, "feat-new")
      stub(Herdr, :list_panes, fn @socket -> panes([pane("w1:p1", a), pane("w3:p1", new)]) end)
      test = self()

      stub(Herdr, :subscribe, fn @socket, subs, _listener ->
        send(test, {:subscribed, subs})
        fake_subscription()
      end)

      house = open(main, backstop_ms: 60_000, id: :match_house)
      # The subscription opened at open, before the mouse existed.
      assert_receive {:subscribed, _at_open}
      leave(main, "mnew", new, "[worktree-status: needs-decision] hello?")

      idle(house)

      assert Map.has_key?(:sys.get_state(house).panes, "w3:p1")
      assert_receive {:subscribed, subs}
      assert %{type: "pane.agent_status_changed", pane_id: "w3:p1"} in subs
    end

    test "a collection from a mouse that already has its pane asks herdr nothing more",
         %{main: main, a: a} do
      # One list at open and no second one: nothing about the mouse is unknown,
      # so a collection from it is not a reason to ask herdr again.
      expect(Herdr, :list_panes, 1, fn @socket -> panes([pane("w1:p1", a)]) end)

      house = open(main, backstop_ms: 60_000, id: :match_house)
      leave(main, "ma", a, "[worktree-status: done]")

      idle(house)

      assert Doorstep.waiting(main) == []
    end
  end

  # The backstop is the last resort, not a working trigger: everything it picks
  # up is something the idle trigger should have picked up first. It went unseen
  # for weeks that the idle trigger had never fired at all (ADR-0036), because the backstop quietly collected every entry a minute
  # late. It says so now.
  describe "the backstop announces what the trigger missed" do
    setup %{a: a} do
      stub(Herdr, :list_panes, fn @socket -> panes([pane("w1:p1", a)]) end)
      stub(Herdr, :subscribe, fn @socket, _, _ -> fake_subscription() end)
      :ok
    end

    test "a backstop collection warns, naming the house and the count", %{main: main, a: a} do
      house = open(main, backstop_ms: 60_000, id: :backstop_house)
      leave(main, "ma", a, "[worktree-status: done]")
      leave(main, "ma", a, "[worktree-status: needs-decision] which one?")

      warning =
        capture_io(:stderr, fn ->
          send(house, :backstop)
          House.sync(house)
        end)

      assert warning =~ "myrepo"
      assert warning =~ "backstop collected 2"
      assert warning =~ "trigger"
    end

    test "it counts them on the house and stamps when", %{main: main, a: a} do
      house = open(main, backstop_ms: 60_000, id: :backstop_house)
      leave(main, "ma", a, "[worktree-status: done]")

      capture_io(:stderr, fn ->
        send(house, :backstop)
        House.sync(house)
      end)

      state = :sys.get_state(house)
      assert state.backstop_collections == 1
      assert %DateTime{} = state.last_backstop_at

      leave(main, "ma", a, "[worktree-status: done]")

      capture_io(:stderr, fn ->
        send(house, :backstop)
        House.sync(house)
      end)

      assert :sys.get_state(house).backstop_collections == 2
    end

    test "it writes the mark the doctor reads", %{main: main, a: a} do
      house = open(main, backstop_ms: 60_000, id: :backstop_house)
      leave(main, "ma", a, "[worktree-status: done]")

      capture_io(:stderr, fn ->
        send(house, :backstop)
        House.sync(house)
      end)

      assert %{count: 1, last: %DateTime{}} = Backstop.read(main)
    end

    test "a backstop that finds nothing is silent and leaves no mark", %{main: main} do
      house = open(main, backstop_ms: 60_000, id: :backstop_house)

      warning =
        capture_io(:stderr, fn ->
          send(house, :backstop)
          House.sync(house)
        end)

      refute warning =~ "backstop"
      assert :sys.get_state(house).backstop_collections == 0
      assert Backstop.read(main) == nil
    end

    # Collecting what landed while the owl was down is the designed path, not a
    # missed trigger (ADR-0036).
    test "what the house collects at open does not count", %{main: main, a: a} do
      leave(main, "ma", a, "[worktree-status: done]")

      warning =
        capture_io(:stderr, fn ->
          house = open(main, backstop_ms: 60_000, id: :backstop_house)
          assert :sys.get_state(house).backstop_collections == 0
        end)

      refute warning =~ "backstop"
      assert Backstop.read(main) == nil
    end

    test "what the idle trigger collects does not count", %{main: main, a: a} do
      house = open(main, backstop_ms: 60_000, id: :backstop_house)
      leave(main, "ma", a, "[worktree-status: done]")

      warning = capture_io(:stderr, fn -> idle(house) end)

      refute warning =~ "backstop"
      assert :sys.get_state(house).backstop_collections == 0
      assert Backstop.read(main) == nil
    end

    test "what an idle retry collects does not count", %{main: main, a: a} do
      house = open(main, backstop_ms: 60_000, retry_ms: [30, 100], id: :backstop_house)

      warning =
        capture_io(:stderr, fn ->
          idle(house)
          leave(main, "ma", a, "[worktree-status: done]")
          Process.sleep(80)
          House.sync(house)
        end)

      assert Doorstep.waiting(main) == []
      refute warning =~ "backstop"
      assert :sys.get_state(house).backstop_collections == 0
      assert Backstop.read(main) == nil
    end

    # The mark says "since this owl opened this house", so a new owl starts
    # clean and the doctor never warns about a run that is over.
    test "opening the house clears an older owl's mark", %{main: main} do
      :ok = Backstop.record(main, 7, DateTime.utc_now())

      open(main, backstop_ms: 60_000, id: :backstop_house)

      assert Backstop.read(main) == nil
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
