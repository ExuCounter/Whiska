defmodule Whiska.Owl.DeliveryTest do
  @moduledoc """
  Getting a collected question in front of the person: the idle-gated queue of
  ADR-0008, the first-of-round wait, the `unknown` row of its table, and how a
  slot frees up again.
  """
  use ExUnit.Case, async: true

  import Mox

  alias Whiska.Delivery.Text
  alias Whiska.Desktop.Mock, as: Desktop
  alias Whiska.Doorstep
  alias Whiska.Doorstep.Entry
  alias Whiska.Herdr.Mock, as: Herdr
  alias Whiska.MergeRequests
  alias Whiska.Owl.House
  alias Whiska.Schema.Question
  alias Whiska.Storage

  setup :verify_on_exit!
  setup {Whiska.Test.QuietSidebar, :stub_sidebar}

  @socket "/fake/herdr.sock"
  @main_pane "w1:p2"
  @mouse_pane "w1R:p1"
  @wait 100
  # The longest a message the house owes may take: the suite runs in parallel,
  # so this is slack, never the thing tested. A refute still waits only @wait.
  @arrives 2_000

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-deliv-#{Whiska.Test.Unique.id()}")
    main = Path.join(root, "myrepo")
    File.mkdir_p!(Path.join(main, ".git"))
    on_exit(fn -> File.rm_rf!(root) end)

    a = Path.join([main, "worktrees", "feat-a"])
    File.mkdir_p!(a)
    {:ok, handle} = Storage.open(main, name: nil)
    {:ok, _} = Storage.record_mouse(%{mouse_id: "ma", path: a, branch: "feat-a"})
    Storage.close(handle)

    stub(Herdr, :list_panes, fn @socket ->
      {:ok, [%{pane_id: @mouse_pane, cwd: a, agent: "claude", agent_status: "working"}]}
    end)

    stub(Herdr, :subscribe, fn @socket, _subs, _listener ->
      {:ok, spawn(fn -> receive do: (:stop -> :ok) end)}
    end)

    # Nobody is typing unless a test says so (ADR-0047).
    box_holds("")

    stub(Desktop, :notify, fn _notification -> {:ok, "osascript"} end)

    {:ok, main: main, a: a}
  end

  defp record_main(main) do
    {:ok, handle} = Storage.open(main, name: nil)
    :ok = Storage.set_main_pane(@main_pane)
    Storage.close(handle)
  end

  defp open(main, opts \\ []) do
    opts =
      Keyword.merge(
        [main_checkout: main, herdr_socket: @socket, backstop_ms: 60_000, round_wait_ms: @wait],
        opts
      )

    pid = start_house(opts)
    House.sync(pid)
    pid
  end

  # The house calls herdr from its own process, from `init/1` on, so it is
  # allowed in by name before it starts — which is what lets this file run async.
  defp start_house(opts) do
    name = :"house-#{System.unique_integer([:positive])}"
    allow(Herdr, self(), fn -> Process.whereis(name) end)
    allow(Desktop, self(), fn -> Process.whereis(name) end)
    start_supervised!({House, [name: name, desktop: Desktop] ++ opts})
  end

  defp in_house(house, fun) do
    Storage.point_at(House.repo(house))
    fun.()
  end

  defp leave(main, root, text) do
    {:ok, _} =
      Doorstep.leave(main, %Entry{
        mouse_id: "ma",
        branch: "feat-a",
        worktree_root: root,
        stamped_at: DateTime.utc_now(),
        text: text
      })
  end

  defp leave_from(main, mouse_id, branch, root, text) do
    {:ok, _} =
      Doorstep.leave(main, %Entry{
        mouse_id: mouse_id,
        branch: branch,
        worktree_root: root,
        stamped_at: DateTime.utc_now(),
        text: text
      })
  end

  defp main_is(status, agent \\ "claude") do
    stub(Herdr, :pane, fn @socket, @main_pane ->
      {:ok, %{pane_id: @main_pane, cwd: "/main", agent: agent, agent_status: status}}
    end)
  end

  # What `pane.read` comes back with: Claude Code's prompt box, drawn with
  # whatever the person has half-typed in it (ADR-0047).
  defp box_holds(draft) do
    screen = """
    ✻ Baked for 46s · done 2:44 PM

    ────────────────────────────────────
    ❯\u00a0#{draft}
    ────────────────────────────────────
      ⏵⏵ auto mode on (shift+tab to cycle)
    """

    stub(Herdr, :read_screen, fn @socket, @main_pane -> {:ok, screen} end)
  end

  # A delivered line arrives as the id it carries; a letter's line as its text.
  defp expect_prompts do
    test = self()

    stub(Herdr, :prompt, fn @socket, pane, text ->
      send(test, {:prompted, pane, Text.id_in(text) || text})
      :ok
    end)
  end

  # herdr streams the per-pane event under its subscription type, with a dot
  # (checked live, 2026-09-28); the main pane sits in the focused tab, so it
  # reports `idle` rather than a background mouse's `done`.
  defp idle(house, pane) do
    send(
      house,
      {:herdr_event, "pane.agent_status_changed", %{"pane_id" => pane, "agent_status" => "idle"}}
    )
  end

  describe "with a main session recorded" do
    setup %{main: main} do
      record_main(main)
      :ok
    end

    test "the house subscribes to the main pane's status changes too", %{main: main} do
      test = self()

      stub(Herdr, :subscribe, fn @socket, subs, _ ->
        send(test, {:subscribed, subs})
        {:ok, spawn(fn -> receive do: (:stop -> :ok) end)}
      end)

      open(main)
      assert_receive {:subscribed, subs}
      assert %{type: "pane.agent_status_changed", pane_id: @main_pane} in subs
    end

    test "the first question of a fresh round waits, then goes when the main session is idle (ADR-0008)",
         %{main: main, a: a} do
      main_is("idle")
      expect_prompts()
      house = open(main)

      leave(main, a, "Which db?\n[worktree-status: needs-decision] pick one")
      House.collect(house)

      refute_receive {:prompted, _, _}, div(@wait, 2)
      assert_receive {:prompted, @main_pane, 1}, @arrives

      in_house(house, fn ->
        assert %Question{status: "sent", sent_at: %DateTime{}} = Storage.question(1)
      end)
    end

    test "questions landing inside the wait go one at a time, oldest first", %{main: main, a: a} do
      main_is("idle")
      expect_prompts()
      # A wait long enough that the second question lands inside it on a loaded machine.
      house = open(main, round_wait_ms: 1_000)

      b = Path.join([main, "worktrees", "feat-b"])
      File.mkdir_p!(b)

      leave(main, a, "[worktree-status: needs-decision] first")
      House.collect(house)

      {:ok, _} =
        Doorstep.leave(main, %Entry{
          mouse_id: "mb",
          branch: "feat-b",
          worktree_root: b,
          stamped_at: DateTime.utc_now(),
          text: "[worktree-status: needs-decision] second"
        })

      House.collect(house)

      assert_receive {:prompted, @main_pane, 1}, @arrives
      refute_receive {:prompted, _, _}, @wait
    end

    test "holds while the main session is working, and goes when herdr reports it idle", %{
      main: main,
      a: a
    } do
      main_is("working")
      expect_prompts()
      house = open(main)

      leave(main, a, "[worktree-status: needs-decision] ?")
      House.collect(house)
      refute_receive {:prompted, _, _}, @wait * 2

      main_is("idle")
      idle(house, @main_pane)
      assert_receive {:prompted, @main_pane, _}, @arrives
    end

    test "a main pane at a dialog is held like working", %{main: main, a: a} do
      main_is("blocked")
      expect_prompts()
      house = open(main)
      leave(main, a, "[worktree-status: needs-decision] ?")
      House.collect(house)
      refute_receive {:prompted, _, _}, @wait * 2
    end

    test "claude + unknown delivers anyway, and says so (ADR-0008)", %{main: main, a: a} do
      main_is("unknown")
      expect_prompts()
      house = open(main)

      leave(main, a, "[worktree-status: needs-decision] ?")
      House.collect(house)

      assert_receive {:prompted, @main_pane, 1}, @arrives
      in_house(house, fn -> assert Storage.question(1).typed_blind end)
    end

    test "a line typed while the person was seen idle is not blind", %{main: main, a: a} do
      main_is("idle")
      expect_prompts()
      house = open(main)

      leave(main, a, "[worktree-status: needs-decision] ?")
      House.collect(house)

      assert_receive {:prompted, @main_pane, _text}, @arrives
      in_house(house, fn -> refute Storage.question(1).typed_blind end)
    end

    test "no agent in the main pane is a dead pane: held, never delivered", %{main: main, a: a} do
      main_is("unknown", nil)
      expect_prompts()
      house = open(main)

      leave(main, a, "[worktree-status: needs-decision] ?")
      House.collect(house)

      refute_receive {:prompted, _, _}, @wait * 2
      in_house(house, fn -> assert Storage.question(1).status == "open" end)
    end

    test "once the first is answered the next starts a fresh round of its own (ADR-0008)",
         %{main: main, a: a} do
      main_is("idle")
      expect_prompts()
      house = open(main)

      leave(main, a, "[worktree-status: needs-decision] one")
      House.collect(house)
      assert_receive {:prompted, @main_pane, 1}, @arrives

      leave(main, a, "[worktree-status: needs-decision] two")
      # A second question from the same mouse would supersede the first, so
      # answer it before collecting the second.
      in_house(house, fn -> {:ok, _} = Storage.answer(1, "go") end)
      House.collect(house)

      # Nothing open, nothing out: a fresh round, so it waits again.
      refute_receive {:prompted, _, _}, div(@wait, 2)
      assert_receive {:prompted, @main_pane, 2}, @arrives
    end

    test "while one is out, a newcomer waits", %{main: main, a: a} do
      main_is("idle")
      expect_prompts()
      house = open(main)

      b = Path.join([main, "worktrees", "feat-b"])
      File.mkdir_p!(b)

      leave(main, a, "[worktree-status: needs-decision] one")
      House.collect(house)
      assert_receive {:prompted, @main_pane, _}, @arrives

      {:ok, _} =
        Doorstep.leave(main, %Entry{
          mouse_id: "mb",
          branch: "feat-b",
          worktree_root: b,
          stamped_at: DateTime.utc_now(),
          text: "[worktree-status: needs-decision] two"
        })

      House.collect(house)
      idle(house, @main_pane)
      refute_receive {:prompted, _, _}, @wait * 2

      in_house(house, fn ->
        assert Storage.question(1).status == "sent"
        assert Storage.question(2).status == "open"
      end)
    end

    test "a newer question from the same mouse supersedes the one already out, freeing the slot",
         %{main: main, a: a} do
      main_is("idle")
      expect_prompts()
      house = open(main)

      leave(main, a, "[worktree-status: needs-decision] one")
      House.collect(house)
      assert_receive {:prompted, @main_pane, _}, @arrives

      leave(main, a, "[worktree-status: needs-decision] two")
      House.collect(house)

      assert_receive {:prompted, @main_pane, 2}, @arrives

      in_house(house, fn ->
        assert Storage.question(1).status == "superseded"
        assert Storage.question(2).status == "sent"
      end)
    end

    # Seen live: the person was discussing a question with the main session, its
    # mouse sent a follow-up, and the freed slot went to another branch's older
    # question, typed into the middle of the conversation.
    test "a newer question from the mouse holding the slot goes next, ahead of another branch's older one",
         %{main: main, a: a} do
      main_is("idle")
      expect_prompts()
      house = open(main)
      b = Path.join([main, "worktrees", "feat-b"])
      File.mkdir_p!(b)

      leave(main, a, "[worktree-status: needs-decision] one")
      House.collect(house)
      assert_receive {:prompted, @main_pane, _}, @arrives

      leave_from(main, "mb", "feat-b", b, "[worktree-status: needs-decision] from b")
      House.collect(house)
      refute_receive {:prompted, _, _}, @wait * 2

      leave(main, a, "[worktree-status: needs-decision] three")
      House.collect(house)
      assert_receive {:prompted, @main_pane, 3}, @arrives

      in_house(house, fn ->
        assert Storage.question(1).status == "superseded"
        assert Storage.question(2).status == "open"
        assert Storage.question(3).status == "sent"
      end)
    end

    test "a finished report is typed, holds nothing, and the question collected after it goes at once",
         %{main: main, a: a} do
      main_is("idle")
      expect_prompts()
      house = open(main)

      finished_from(main, "mc", "feat-c")
      House.collect(house)
      assert_receive {:prompted, @main_pane, 1}, @arrives

      leave(main, a, "[worktree-status: needs-decision] pick one")
      House.collect(house)
      assert_receive {:prompted, @main_pane, 2}, @arrives

      in_house(house, fn ->
        assert %{status: "closed", typed_at: %DateTime{}} = Storage.question(1)
      end)
    end

    test "a mouse's finished report that replaces its question out frees the slot for another branch's",
         %{main: main, a: a} do
      main_is("idle")
      expect_prompts()
      house = open(main)
      b = Path.join([main, "worktrees", "feat-b"])
      File.mkdir_p!(b)

      leave(main, a, "[worktree-status: needs-decision] one")
      House.collect(house)
      assert_receive {:prompted, @main_pane, _}, @arrives

      leave_from(main, "mb", "feat-b", b, "[worktree-status: needs-decision] from b")
      House.collect(house)
      refute_receive {:prompted, _, _}, @wait * 2

      leave(main, a, "Merged it.\n[worktree-status: done]")
      House.collect(house)
      assert_receive {:prompted, @main_pane, 2}, @arrives

      in_house(house, fn ->
        assert Storage.question(1).status == "superseded"
        assert Storage.question(2).status == "sent"
        assert Storage.question(3).status == "closed"
      end)
    end

    test "herdr refusing the prompt leaves the question open for the next attempt", %{
      main: main,
      a: a
    } do
      main_is("idle")
      test = self()

      Herdr
      |> expect(:prompt, fn @socket, @main_pane, _ ->
        send(test, :refused)
        {:error, {:herdr, %{"code" => "agent_blocked", "message" => "dialog"}}}
      end)
      |> expect(:prompt, fn @socket, @main_pane, text ->
        send(test, {:prompted, text})
        :ok
      end)

      house = open(main)
      leave(main, a, "[worktree-status: needs-decision] ?")
      House.collect(house)

      assert_receive :refused, @arrives
      in_house(house, fn -> assert Storage.question(1).status == "open" end)

      idle(house, @main_pane)
      assert_receive {:prompted, _}, @arrives
      in_house(house, fn -> assert Storage.question(1).status == "sent" end)
    end

    test "the backstop retries delivery on its own", %{main: main, a: a} do
      main_is("working")
      expect_prompts()
      house = open(main, backstop_ms: @wait)

      leave(main, a, "[worktree-status: needs-decision] ?")
      House.collect(house)
      refute_receive {:prompted, _, _}, @wait * 2

      main_is("idle")
      assert_receive {:prompted, @main_pane, _}, @arrives
    end

    test "a done report supersedes the mouse's earlier questions, is hooted, and typed with no second hoot (ADR-0009)",
         %{main: main, a: a} do
      test = self()
      stub(Desktop, :notify, fn hoot -> send(test, {:hooted, hoot}) && {:ok, "osascript"} end)
      main_is("idle")
      expect_prompts()
      house = open(main)

      leave(main, a, "[worktree-status: needs-decision] one")
      House.collect(house)
      assert_receive {:prompted, @main_pane, _}, @arrives
      assert_receive {:hooted, %{sound: :request}}, @arrives

      leave(main, a, "Merged it.\n[worktree-status: done]")
      House.collect(house)
      assert_receive {:hooted, hoot}, @arrives
      assert hoot.title =~ "feat-a finished"
      assert hoot.body =~ "#2"
      assert hoot.sound == :done
      assert_receive {:prompted, @main_pane, 2}, @arrives
      refute_receive {:hooted, _}, @wait * 2

      in_house(house, fn ->
        assert Storage.question(1).status == "superseded"

        assert %{status: "closed", hooted_at: %DateTime{}, typed_at: %DateTime{}} =
                 Storage.question(2)
      end)

      refute File.exists?(Path.join(main, ".git/whiska-finish"))
    end

    test "a mouse's reply to a letter arrives closed, holds nothing, and is typed and hooted as a reply",
         %{main: main, a: a} do
      test = self()
      stub(Desktop, :notify, fn hoot -> send(test, {:hooted, hoot}) && {:ok, "osascript"} end)
      main_is("idle")
      expect_prompts()
      house = open(main)

      {:ok, _} =
        Doorstep.leave(main, %Entry{
          mouse_id: "ma",
          branch: "feat-a",
          worktree_root: a,
          stamped_at: DateTime.utc_now(),
          text: "Here is the answer; the reviewers are still running.",
          reply: true
        })

      House.collect(house)
      assert_receive {:prompted, @main_pane, 1}, @arrives
      assert_receive {:hooted, hoot}, @arrives
      assert hoot.title =~ "feat-a replied"

      leave(main, a, "[worktree-status: needs-decision] pick one")
      House.collect(house)
      assert_receive {:prompted, @main_pane, 2}, @arrives

      in_house(house, fn ->
        assert %{status: "closed", reply: true, kind: "unmarked", typed_at: %DateTime{}} =
                 Storage.question(1)
      end)
    end

    test "a reply waits untyped behind a question out, then goes", %{main: main, a: a} do
      main_is("idle")
      expect_prompts()
      house = open(main)
      b = Path.join([main, "worktrees", "feat-b"])
      File.mkdir_p!(b)

      leave_from(main, "mb", "feat-b", b, "[worktree-status: needs-decision] from b")
      House.collect(house)
      assert_receive {:prompted, @main_pane, 1}, @arrives

      {:ok, _} =
        Doorstep.leave(main, %Entry{
          mouse_id: "ma",
          branch: "feat-a",
          worktree_root: a,
          stamped_at: DateTime.utc_now(),
          text: "Answered; reviewers still running.",
          reply: true
        })

      House.collect(house)
      idle(house, @main_pane)
      House.sync(house)
      refute_received {:prompted, _, _}

      in_house(house, fn ->
        assert %{status: "closed", typed_at: nil} = Storage.question(2)
        {:ok, _} = Storage.answer(1, "A")
      end)

      idle(house, @main_pane)
      assert_receive {:prompted, @main_pane, 2}, @arrives
    end

    test "a reply to a letter that took a sent question's place goes ahead of another branch's",
         %{main: main, a: a} do
      main_is("idle")
      expect_prompts()
      house = open(main)
      b = Path.join([main, "worktrees", "feat-b"])
      File.mkdir_p!(b)

      leave(main, a, "[worktree-status: needs-decision] from a")
      House.collect(house)
      assert_receive {:prompted, @main_pane, 1}, @arrives

      leave_from(main, "mb", "feat-b", b, "[worktree-status: needs-decision] from b")
      House.collect(house)
      in_house(house, fn -> {:ok, [1]} = Storage.supersede_for_letter("ma", [1]) end)

      {:ok, _} =
        Doorstep.leave(main, %Entry{
          mouse_id: "ma",
          branch: "feat-a",
          worktree_root: a,
          stamped_at: DateTime.utc_now(),
          text: "Answered; reviewers still running.",
          reply: true
        })

      House.collect(house)
      assert_receive {:prompted, @main_pane, 3}, @arrives

      idle(house, @main_pane)
      assert_receive {:prompted, @main_pane, 2}, @arrives
    end

    test "a reply is typed even once its mouse has said more since", %{main: main, a: a} do
      main_is("idle")
      expect_prompts()
      house = open(main)
      b = Path.join([main, "worktrees", "feat-b"])
      File.mkdir_p!(b)

      leave_from(main, "mb", "feat-b", b, "[worktree-status: needs-decision] from b")
      House.collect(house)
      assert_receive {:prompted, @main_pane, 1}, @arrives

      {:ok, _} =
        Doorstep.leave(main, %Entry{
          mouse_id: "ma",
          branch: "feat-a",
          worktree_root: a,
          stamped_at: DateTime.utc_now(),
          text: "Answered; reviewers still running.",
          reply: true
        })

      House.collect(house)
      leave(main, a, "[worktree-status: needs-decision] then this")
      House.collect(house)

      in_house(house, fn -> {:ok, _} = Storage.answer(1, "A") end)
      idle(house, @main_pane)
      assert_receive {:prompted, @main_pane, 3}, @arrives

      in_house(house, fn -> {:ok, _} = Storage.answer(3, "B") end)
      idle(house, @main_pane)
      assert_receive {:prompted, @main_pane, 2}, @arrives
    end

    test "a finished report hoots while a decision is out, and waits untyped behind it", %{
      main: main,
      a: a
    } do
      test = self()
      stub(Desktop, :notify, fn hoot -> send(test, {:hooted, hoot}) && {:ok, "osascript"} end)
      main_is("idle")
      expect_prompts()
      house = open(main)

      leave(main, a, "[worktree-status: needs-decision] pick one")
      House.collect(house)
      assert_receive {:prompted, @main_pane, _}, @arrives
      assert_receive {:hooted, %{sound: :request}}, @arrives

      finished_from(main, "mb", "feat-b")
      House.collect(house)
      assert_receive {:hooted, %{sound: :done, title: title}}, @arrives
      assert title =~ "feat-b finished"
      idle(house, @main_pane)
      House.sync(house)
      refute_received {:prompted, _, _}
      refute_received {:hooted, _}

      in_house(house, fn ->
        assert Storage.question(1).status == "sent"
        assert Storage.question(2).status == "closed"
        {:ok, _} = Storage.answer(1, "A")
      end)

      idle(house, @main_pane)
      assert_receive {:prompted, @main_pane, 2}, @arrives
    end

    test "a finished report hoots while the main session is working, and is typed once it is idle",
         %{main: main, a: a} do
      test = self()
      stub(Desktop, :notify, fn hoot -> send(test, {:hooted, hoot}) && {:ok, "osascript"} end)
      main_is("working")
      expect_prompts()
      house = open(main)

      leave(main, a, "[worktree-status: done]")
      House.collect(house)
      assert_receive {:hooted, %{sound: :done}}, @arrives
      refute_receive {:prompted, _, _}, @wait * 2

      main_is("idle")
      idle(house, @main_pane)
      assert_receive {:prompted, @main_pane, 1}, @arrives
    end

    test "once the slot frees, the question queued behind it goes, counting no finished report",
         %{main: main, a: a} do
      main_is("idle")
      expect_prompts()
      house = open(main)

      leave(main, a, "[worktree-status: needs-decision] pick one")
      House.collect(house)
      assert_receive {:prompted, @main_pane, _}, @arrives

      b = Path.join([main, "worktrees", "feat-b"])
      File.mkdir_p!(b)
      leave_from(main, "mb", "feat-b", b, "[worktree-status: needs-decision] and this one")
      House.collect(house)
      finished_from(main, "mc", "feat-c")
      House.collect(house)
      refute_receive {:prompted, _, _}, @wait * 2

      in_house(house, fn -> {:ok, _} = Storage.answer(1, "A") end)
      idle(house, @main_pane)
      assert_receive {:prompted, @main_pane, 2}, @arrives
    end
  end

  describe "finished branches (ADR-0062)" do
    setup %{main: main} do
      record_main(main)
      main_is("idle")
      expect_prompts()
      test = self()
      stub(Desktop, :notify, fn hoot -> send(test, {:hooted, hoot}) && {:ok, "osascript"} end)
      :ok
    end

    test "each finished branch hoots once, then all are reminded in one hoot every remind_ms",
         %{main: main} do
      finished_from(main, "mb", "feat-b")
      finished_from(main, "mc", "feat-c")
      open(main, backstop_ms: 20, remind_ms: 400)

      assert_receive {:hooted, %{title: one}}, @arrives
      assert_receive {:hooted, %{title: two}}, @arrives
      assert one <> two =~ "feat-b finished"
      assert one <> two =~ "feat-c finished"

      assert_receive {:hooted, first}, @arrives
      reminded = System.monotonic_time(:millisecond)
      assert first.title =~ "2 finished, not landed"
      assert first.body =~ "feat-b"
      assert first.body =~ "feat-c"

      assert_receive {:hooted, second}, @arrives
      assert System.monotonic_time(:millisecond) - reminded >= 300
      assert second.title =~ "2 finished, not landed"
      assert_received {:prompted, @main_pane, 1}
      assert_received {:prompted, @main_pane, 2}
    end

    test "a branch with a merge request still hoots its finish, and is never reminded", %{
      main: main
    } do
      finished_from(main, "mb", "feat-b")

      seed(main, fn ->
        {:ok, _} =
          Storage.record_mouse(%{
            mouse_id: "mb",
            path: Path.join([main, "worktrees", "feat-b"]),
            branch: "feat-b"
          })

        {:ok, _} = Storage.record_merge_request("mb", "https://gitlab.example/mr/1")
      end)

      open(main, backstop_ms: 20, remind_ms: 300)

      assert_receive {:hooted, %{title: "🐱 myrepo · feat-b finished"}}, @arrives
      refute_receive {:hooted, _}, 800
    end

    test "the report ending a review round the owl handed over hoots and is typed only if the round pushed",
         %{main: main} do
      round_at = DateTime.add(DateTime.utc_now(), -60) |> DateTime.truncate(:second)

      seed(main, fn ->
        for {id, branch, head} <- [{"mb", "feat-b", "h1"}, {"mc", "feat-c", "h2"}] do
          url = "https://gitlab.example.com/acme/app/-/merge_requests/#{branch}"
          path = Path.join([main, "worktrees", branch])
          {:ok, _} = Storage.record_mouse(%{mouse_id: id, path: path, branch: branch})
          {:ok, _} = Storage.record_merge_request(id, url)

          :ok =
            MergeRequests.save(%{
              mouse_id: id,
              url: url,
              state: "open",
              head_sha: head,
              round_at: round_at,
              round_by: "woke",
              round_head: "h1"
            })
        end
      end)

      finished_from(main, "mb", "feat-b")
      finished_from(main, "mc", "feat-c")
      open(main, backstop_ms: 20, remind_ms: 60_000)

      assert_receive {:hooted, %{title: "🐱 myrepo · feat-c finished"}}, @arrives
      assert_receive {:prompted, @main_pane, 2}, @arrives
      refute_receive {:hooted, %{title: "🐱 myrepo · feat-b finished"}}, 500
      refute_received {:prompted, _, 1}
    end

    test "a finished report collected into a quiet house is typed at once: the question after it waits its own round",
         %{main: main, a: a} do
      house = open(main, round_wait_ms: 1_500)

      finished_from(main, "mb", "feat-b")
      House.collect(house)
      assert_receive {:hooted, _}, @arrives
      assert_receive {:prompted, @main_pane, 1}, @arrives
      Process.sleep(400)

      leave(main, a, "[worktree-status: needs-decision] pick one")
      House.collect(house)
      refute_receive {:prompted, _, _}, 1_200
      assert_receive {:prompted, @main_pane, _}, @arrives
    end

    test "a branch its mouse took up again is reminded no more", %{main: main} do
      root = Path.join([main, "worktrees", "feat-b"])
      File.mkdir_p!(root)

      seed(main, fn ->
        {:ok, _} = Storage.record_mouse(%{mouse_id: "mb", path: root, branch: "feat-b"})

        {:ok, report} =
          Storage.record_question(%{
            mouse_id: "mb",
            text: "Done.",
            kind: "done",
            status: "closed"
          })

        :ok = Storage.hooted([report.id], DateTime.add(DateTime.utc_now(), -3, :hour))
        {:ok, _} = Storage.set_working("mb", DateTime.add(report.asked_at, 1))
      end)

      open(main, backstop_ms: 20, remind_ms: 300)
      refute_receive {:hooted, _}, 800
    end
  end

  defp finished_from(main, mouse_id, branch) do
    root = Path.join([main, "worktrees", branch])
    File.mkdir_p!(root)
    leave_from(main, mouse_id, branch, root, "Merged it.\n[worktree-status: done]")
  end

  # ADR-0026: a mouse whose pane is gone is dead, and ADR-0007 cascades what it
  # left waiting to `orphaned`. Until this was fixed the cascade skipped `sent`,
  # so a question already delivered to a mouse that then died held ADR-0008's
  # one slot forever and every later question stayed `open`, undelivered.
  describe "a mouse that died holding the delivery slot" do
    setup %{main: main} do
      record_main(main)
      b = Path.join([main, "worktrees", "feat-b"])
      File.mkdir_p!(b)

      {:ok, handle} = Storage.open(main, name: nil)
      {:ok, _} = Storage.record_mouse(%{mouse_id: "mb", path: b, branch: "feat-b"})

      {:ok, out} =
        Storage.record_question(%{mouse_id: "ma", text: "which one?", kind: "needs-decision"})

      {:ok, _} = Storage.mark_sent(out.id)

      {:ok, _} =
        Storage.record_question(%{mouse_id: "mb", text: "and this one?", kind: "needs-decision"})

      Storage.close(handle)

      {:ok, b: b}
    end

    defp pane_for(root, pane_id) do
      %{pane_id: pane_id, cwd: root, agent: "claude", agent_status: "working"}
    end

    test "opening the house frees the slot and delivers the next question by itself",
         %{main: main, b: b} do
      main_is("idle")
      expect_prompts()

      # feat-a's pane is gone: the mouse died while the owl was down.
      stub(Herdr, :list_panes, fn @socket -> {:ok, [pane_for(b, "w1R:p9")]} end)

      house = open(main)

      assert_receive {:prompted, @main_pane, 2}, @arrives

      in_house(house, fn ->
        assert Storage.mouse("ma").died_at != nil
        assert Storage.question(1).status == "orphaned"
        assert Storage.question(2).status == "sent"
      end)
    end

    test "the backstop frees it too, for a mouse that died with the owl up",
         %{main: main, a: a, b: b} do
      main_is("idle")
      expect_prompts()

      stub(Herdr, :list_panes, fn @socket ->
        {:ok, [pane_for(a, @mouse_pane), pane_for(b, "w1R:p9")]}
      end)

      house = open(main, backstop_ms: @wait)

      # Both mice alive: the slot is legitimately held, nothing goes out.
      refute_receive {:prompted, _, _}, @wait * 2

      stub(Herdr, :list_panes, fn @socket -> {:ok, [pane_for(b, "w1R:p9")]} end)

      assert_receive {:prompted, @main_pane, 2}, @arrives

      in_house(house, fn ->
        assert Storage.question(1).status == "orphaned"
        assert Storage.question(2).status == "sent"
      end)
    end
  end

  # Nothing that cannot be answered may hold the one delivery slot (ADR-0008).
  describe "a question nothing can answer" do
    setup %{main: main} do
      record_main(main)
      :ok
    end

    test "a question collected after its mouse died never takes the slot",
         %{main: main, a: a} do
      main_is("idle")
      expect_prompts()

      b = Path.join([main, "worktrees", "feat-b"])
      File.mkdir_p!(b)

      # feat-a's pane is gone, so the house marks it dead at open; its entry is
      # collected afterwards, which is how #5 wedged platform's queue.
      stub(Herdr, :list_panes, fn @socket ->
        {:ok, [%{pane_id: "w1R:p9", cwd: b, agent: "claude", agent_status: "working"}]}
      end)

      house = open(main)
      in_house(house, fn -> assert Storage.mouse("ma").died_at != nil end)

      leave(main, a, "[worktree-status: needs-decision] too late")
      House.collect(house)
      refute_receive {:prompted, _, _}, @wait * 3

      leave_from(main, "mb", "feat-b", b, "[worktree-status: needs-decision] mine")
      {:ok, handle} = Storage.open(main, name: nil)
      {:ok, _} = Storage.record_mouse(%{mouse_id: "mb", path: b, branch: "feat-b"})
      Storage.close(handle)
      House.collect(house)

      assert_receive {:prompted, @main_pane, 2}, @arrives

      in_house(house, fn ->
        assert Storage.question(1).status == "orphaned"
        assert Storage.question(2).status == "sent"
      end)
    end

    test "a finished report from a dead mouse is still hooted and typed", %{main: main, a: a} do
      test = self()
      stub(Desktop, :notify, fn hoot -> send(test, {:hooted, hoot}) && {:ok, "osascript"} end)
      main_is("idle")
      expect_prompts()

      b = Path.join([main, "worktrees", "feat-b"])
      File.mkdir_p!(b)

      stub(Herdr, :list_panes, fn @socket ->
        {:ok, [%{pane_id: "w1R:p9", cwd: b, agent: "claude", agent_status: "working"}]}
      end)

      house = open(main)
      in_house(house, fn -> assert Storage.mouse("ma").died_at != nil end)

      leave(main, a, "All done.\n\u2063\u2063\u2063")
      House.collect(house)

      assert_receive {:hooted, %{sound: :done, title: title}}, @arrives
      assert title =~ "feat-a finished"
      assert_receive {:prompted, @main_pane, 1}, @arrives
    end

    test "a record that no longer stands for a worktree lets the slot go",
         %{main: main} do
      main_is("idle")
      expect_prompts()

      # The phantom a slashed branch's parent folder used to mint, with the
      # real mouse nested inside it (ADR-0082, ADR-0030).
      phantom = Path.join([main, "worktrees", "quality"])
      real = Path.join(phantom, "QUAL-350")
      File.mkdir_p!(real)

      {:ok, handle} = Storage.open(main, name: nil)

      {:ok, _} =
        Storage.record_mouse(%{
          mouse_id: "phantom",
          path: phantom,
          branch: "quality",
          created_at: ~U[2026-09-29 10:00:00Z]
        })

      {:ok, _} =
        Storage.record_mouse(%{
          mouse_id: "qual",
          path: real,
          branch: "quality/QUAL-350",
          created_at: ~U[2026-09-29 11:00:00Z]
        })

      {:ok, wedged} =
        Storage.record_question(%{mouse_id: "phantom", text: "#5", kind: "needs-decision"})

      {:ok, _} = Storage.mark_sent(wedged.id)
      Storage.close(handle)

      stub(Herdr, :list_panes, fn @socket ->
        {:ok, [%{pane_id: "w1R:p9", cwd: real, agent: "claude", agent_status: "working"}]}
      end)

      house = open(main)
      leave_from(main, "qual", "quality/QUAL-350", real, "[worktree-status: needs-decision] mine")
      House.collect(house)

      assert_receive {:prompted, @main_pane, 2}, @arrives

      in_house(house, fn -> assert Storage.question(wedged.id).status == "orphaned" end)
    end
  end

  describe "while the person is typing in the main session (ADR-0047)" do
    setup %{main: main} do
      record_main(main)
      main_is("idle")
      expect_prompts()
      :ok
    end

    test "a half-typed prompt holds delivery even though herdr says idle", %{main: main, a: a} do
      box_holds("a thought I have not finished")
      house = open(main)

      leave(main, a, "[worktree-status: needs-decision] ?")
      House.collect(house)

      refute_receive {:prompted, _, _}, @wait * 3
      in_house(house, fn -> assert Storage.question(1).status == "open" end)
    end

    test "Claude Code's faint suggestion in an empty box does not hold delivery",
         %{main: main, a: a} do
      screen =
        File.read!(Path.expand("../../support/screens/suggestion-in-an-empty-box.ansi", __DIR__))

      stub(Herdr, :read_screen, fn @socket, @main_pane -> {:ok, screen} end)
      house = open(main)

      leave(main, a, "[worktree-status: needs-decision] ?")
      House.collect(house)

      assert_receive {:prompted, @main_pane, _}, @arrives
    end

    test "the question goes on the next trigger once the box is empty again", %{
      main: main,
      a: a
    } do
      box_holds("still typing")
      house = open(main, backstop_ms: @wait)

      leave(main, a, "[worktree-status: needs-decision] ?")
      House.collect(house)
      refute_receive {:prompted, _, _}, @wait * 2

      box_holds("")
      assert_receive {:prompted, @main_pane, _}, @arrives
      in_house(house, fn -> assert Storage.question(1).status == "sent" end)
    end

    test "a screen with no prompt box on it holds — there is nowhere to type (ADR-0047)",
         %{main: main, a: a} do
      stub(Herdr, :read_screen, fn @socket, @main_pane -> {:ok, "a dialog is up\n"} end)
      house = open(main, hold_notice_ms: 0)

      leave(main, a, "[worktree-status: needs-decision] ?")
      House.collect(house)

      refute_receive {:prompted, _, _}, @wait * 3
      assert House.sync(house) == :ok
      assert House.held(house) == :no_box
      in_house(house, fn -> assert Storage.question(1).status == "open" end)
    end

    test "the box coming back on screen releases the hold", %{main: main, a: a} do
      stub(Herdr, :read_screen, fn @socket, @main_pane -> {:ok, "a dialog is up\n"} end)
      house = open(main, backstop_ms: @wait)

      leave(main, a, "[worktree-status: needs-decision] ?")
      House.collect(house)
      refute_receive {:prompted, _, _}, @wait * 2

      box_holds("")
      assert_receive {:prompted, @main_pane, _}, @arrives
    end

    test "a box Whiska cannot read delivers anyway — ADR-0008's unavailable signal",
         %{main: main, a: a} do
      screen = "────────────────\n» some later Claude Code\n────────────────\n"
      stub(Herdr, :read_screen, fn @socket, @main_pane -> {:ok, screen} end)
      house = open(main)

      leave(main, a, "[worktree-status: needs-decision] ?")
      House.collect(house)

      assert_receive {:prompted, @main_pane, _}, @arrives
    end

    test "a pane.read herdr refuses delivers anyway", %{main: main, a: a} do
      stub(Herdr, :read_screen, fn @socket, @main_pane -> {:error, :nope} end)
      house = open(main)

      leave(main, a, "[worktree-status: needs-decision] ?")
      House.collect(house)

      assert_receive {:prompted, @main_pane, _}, @arrives
    end
  end

  describe "a hold the board can see (ADR-0082)" do
    setup %{main: main} do
      record_main(main)
      :ok
    end

    test "a delivery herdr refuses is a hold, not a clean slate", %{main: main, a: a} do
      main_is("idle")

      stub(Herdr, :prompt, fn @socket, @main_pane, _text ->
        {:error, {:herdr, %{"code" => "agent_blocked"}}}
      end)

      house = open(main, hold_notice_ms: 0)
      leave(main, a, "[worktree-status: needs-decision] ?")
      House.collect(house)
      Process.sleep(@wait * 2)
      assert House.sync(house) == :ok

      assert House.held(house) == :unreachable
    end

    test "a hold that changes its reason is still one hold", %{main: main, a: a} do
      main_is("working")
      expect_prompts()

      house = open(main, hold_notice_ms: 60_000)
      leave(main, a, "[worktree-status: needs-decision] ?")
      House.collect(house)
      Process.sleep(@wait * 2)
      assert House.sync(house) == :ok
      first = House.held_since(house)
      assert House.held(house) == :mid_turn

      main_is("idle")
      box_holds("half a sentence")
      idle(house, @main_pane)
      assert House.sync(house) == :ok

      assert House.held(house) == :typing
      assert House.held_since(house) == first
    end
  end

  describe "what the person set aside (ADR-0079)" do
    setup %{main: main, a: a} do
      record_main(main)
      main_is("idle")
      expect_prompts()

      b = Path.join([main, "worktrees", "feat-b"])
      File.mkdir_p!(b)

      stub(Herdr, :list_panes, fn @socket ->
        {:ok,
         [
           %{pane_id: @mouse_pane, cwd: a, agent: "claude", agent_status: "working"},
           %{pane_id: "w1R:p3", cwd: b, agent: "claude", agent_status: "working"}
         ]}
      end)

      away = Path.join(Path.dirname(main), "away-#{System.unique_integer([:positive])}")
      {:ok, b: b, away: away}
    end

    defp seed(main, fun) do
      {:ok, handle} = Storage.open(main, name: nil)
      fun.()
      Storage.close(handle)
    end

    test "while away nothing is delivered, and the question stays open", %{
      main: main,
      a: a,
      away: away
    } do
      :ok = Whiska.Delivery.Mode.set_away(away)
      house = open(main, away_path: away)

      leave(main, a, "[worktree-status: needs-decision] ?")
      House.collect(house)
      Process.sleep(@wait * 2)
      idle(house, @main_pane)
      refute_receive {:prompted, _, _}, @wait * 2

      in_house(house, fn -> assert Storage.question(1).status == "open" end)
    end

    test "a finished report collected while away is hooted and typed once the person is back", %{
      main: main,
      a: a,
      away: away
    } do
      test = self()
      stub(Desktop, :notify, fn hoot -> send(test, {:hooted, hoot}) && {:ok, "osascript"} end)
      :ok = Whiska.Delivery.Mode.set_away(away)
      house = open(main, away_path: away, board_ms: 20, panes_ms: 20)

      leave(main, a, "all done\n[worktree-status: done]")
      House.collect(house)
      refute_receive {:hooted, _}, @wait * 2
      in_house(house, fn -> assert Storage.question(1).hooted_at == nil end)

      refute_receive {:prompted, _, _}, @wait

      :ok = Whiska.Delivery.Mode.clear_away(away)
      assert_receive {:hooted, %{sound: :done}}, @arrives
      assert_receive {:prompted, @main_pane, 1}, @arrives
    end

    test "a reminder that came due while away goes out once the person is back", %{
      main: main,
      b: b,
      away: away
    } do
      test = self()
      stub(Desktop, :notify, fn hoot -> send(test, {:hooted, hoot}) && {:ok, "osascript"} end)

      seed(main, fn ->
        {:ok, _} = Storage.record_mouse(%{mouse_id: "mb", path: b, branch: "feat-b"})

        {:ok, report} =
          Storage.record_question(%{
            mouse_id: "mb",
            text: "Done.",
            kind: "done",
            status: "closed"
          })

        :ok = Storage.hooted([report.id], DateTime.add(DateTime.utc_now(), -3, :hour))
      end)

      :ok = Whiska.Delivery.Mode.set_away(away)

      open(main,
        away_path: away,
        board_ms: 20,
        panes_ms: 20,
        backstop_ms: 60_000,
        remind_ms: 200
      )

      refute_receive {:hooted, _}, 500
      :ok = Whiska.Delivery.Mode.clear_away(away)
      assert_receive {:hooted, %{title: "🐱 myrepo · 1 finished, not landed"}}, @arrives
    end

    test "coming back is noticed on the board's own tick, and the oldest goes first", %{
      main: main,
      a: a,
      b: b,
      away: away
    } do
      :ok = Whiska.Delivery.Mode.set_away(away)
      house = open(main, away_path: away, board_ms: 20, panes_ms: 20)

      leave(main, a, "[worktree-status: needs-decision] first")
      House.collect(house)
      leave_from(main, "mb", "feat-b", b, "[worktree-status: needs-decision] second")
      House.collect(house)
      Process.sleep(@wait * 2)
      refute_receive {:prompted, _, _}, @wait

      :ok = Whiska.Delivery.Mode.clear_away(away)

      assert_receive {:prompted, @main_pane, 1}, @arrives
    end

    test "under a focus only the focused mouse's question goes, although another's is sent", %{
      main: main,
      a: a,
      b: b,
      away: away
    } do
      seed(main, fn ->
        {:ok, _} = Storage.record_mouse(%{mouse_id: "mb", path: b, branch: "feat-b"})
      end)

      house = open(main, away_path: away)

      leave(main, a, "[worktree-status: needs-decision] a asks")
      House.collect(house)
      assert_receive {:prompted, @main_pane, 1}, @arrives

      in_house(house, fn -> :ok = Storage.set_focus("mb") end)

      leave_from(main, "mb", "feat-b", b, "[worktree-status: needs-decision] b asks")
      House.collect(house)
      idle(house, @main_pane)

      assert_receive {:prompted, @main_pane, 2}, @arrives

      in_house(house, fn ->
        assert Storage.question(1).status == "sent"
        assert Storage.question(2).status == "sent"
      end)
    end

    test "under a focus the other mice's questions wait, listed but not delivered", %{
      main: main,
      a: a,
      b: b,
      away: away
    } do
      seed(main, fn ->
        {:ok, _} = Storage.record_mouse(%{mouse_id: "mb", path: b, branch: "feat-b"})
        :ok = Storage.set_focus("mb")
      end)

      house = open(main, away_path: away)
      leave(main, a, "[worktree-status: needs-decision] a asks")
      House.collect(house)
      Process.sleep(@wait * 2)
      idle(house, @main_pane)
      refute_receive {:prompted, _, _}, @wait * 2

      in_house(house, fn -> assert Storage.question(1).status == "open" end)
    end

    test "a held mouse's question is never delivered, and its sent one frees the slot", %{
      main: main,
      a: a,
      b: b,
      away: away
    } do
      seed(main, fn ->
        {:ok, _} = Storage.record_mouse(%{mouse_id: "mb", path: b, branch: "feat-b"})
      end)

      house = open(main, away_path: away)

      leave(main, a, "[worktree-status: needs-decision] a asks")
      House.collect(house)
      assert_receive {:prompted, @main_pane, 1}, @arrives

      in_house(house, fn -> {:ok, _} = Storage.hold("ma") end)

      leave_from(main, "mb", "feat-b", b, "[worktree-status: needs-decision] b asks")
      House.collect(house)
      idle(house, @main_pane)
      assert_receive {:prompted, @main_pane, 2}, @arrives

      in_house(house, fn -> {:ok, _} = Storage.answer(2, "go") end)
      leave(main, a, "[worktree-status: needs-decision] a stopped where it was")
      House.collect(house)
      Process.sleep(@wait * 2)
      idle(house, @main_pane)
      refute_receive {:prompted, _, _}, @wait * 2

      in_house(house, fn ->
        assert Storage.question(1).status == "superseded"
        assert Storage.question(3).status == "open"
      end)
    end

    test "a held mouse's finished report is not hooted or typed until the hold lifts", %{
      main: main,
      a: a,
      away: away
    } do
      test = self()
      stub(Desktop, :notify, fn hoot -> send(test, {:hooted, hoot}) && {:ok, "osascript"} end)
      seed(main, fn -> {:ok, _} = Storage.hold("ma") end)
      house = open(main, away_path: away, board_ms: 20, panes_ms: 20)

      leave(main, a, "all done\n[worktree-status: done]")
      House.collect(house)
      refute_receive {:hooted, _}, @wait * 2

      refute_receive {:prompted, _, _}, @wait

      in_house(house, fn -> {:ok, _} = Storage.lift_hold("ma") end)
      assert_receive {:hooted, %{sound: :done}}, @arrives
      assert_receive {:prompted, @main_pane, 1}, @arrives
    end

    test "a hold lifted is noticed on the tick too", %{main: main, a: a, away: away} do
      seed(main, fn -> {:ok, _} = Storage.hold("ma") end)
      house = open(main, away_path: away, board_ms: 20, panes_ms: 20)

      leave(main, a, "[worktree-status: needs-decision] ?")
      House.collect(house)
      Process.sleep(@wait * 2)
      refute_receive {:prompted, _, _}, @wait

      in_house(house, fn -> {:ok, _} = Storage.lift_hold("ma") end)

      assert_receive {:prompted, @main_pane, _}, @arrives
    end
  end

  describe "with no main session recorded" do
    test "nothing is delivered and the question stays open, waiting for whiska start", %{
      main: main,
      a: a
    } do
      # No pane/prompt stubs: Mox would fail the test if the house asked herdr.
      house = open(main)
      leave(main, a, "[worktree-status: needs-decision] ?")
      House.collect(house)
      Process.sleep(@wait * 2)
      House.sync(house)

      in_house(house, fn -> assert Storage.question(1).status == "open" end)
    end

    test "a question nothing can answer is still released", %{main: main, a: a} do
      b = Path.join([main, "worktrees", "feat-b"])
      File.mkdir_p!(b)

      stub(Herdr, :list_panes, fn @socket ->
        {:ok, [%{pane_id: "w1R:p9", cwd: b, agent: "claude", agent_status: "working"}]}
      end)

      house = open(main)
      leave(main, a, "[worktree-status: needs-decision] ?")
      House.collect(house)
      Process.sleep(@wait * 2)
      assert House.sync(house) == :ok

      in_house(house, fn -> assert Storage.question(1).status == "orphaned" end)
    end

    test "recording one later is picked up by the backstop", %{main: main, a: a} do
      test = self()
      house = open(main, backstop_ms: @wait)
      leave(main, a, "[worktree-status: needs-decision] ?")
      House.collect(house)

      record_main(main)
      main_is("idle")

      stub(Herdr, :prompt, fn @socket, @main_pane, text ->
        send(test, {:prompted, text})
        :ok
      end)

      assert_receive {:prompted, _}, @arrives
    end
  end
end
