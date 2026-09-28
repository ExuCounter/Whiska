defmodule Whiska.Owl.DeliveryTest do
  @moduledoc """
  Getting a collected question in front of the person: the idle-gated queue of
  ADR-0008, the first-of-round wait, the `unknown` row of its table, and how a
  slot frees up again.
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
  @main_pane "w1:p2"
  @mouse_pane "w1R:p1"
  @wait 100

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-deliv-#{System.unique_integer([:positive])}")
    main = Path.join(root, "myrepo")
    File.mkdir_p!(Path.join(main, ".git"))
    on_exit(fn -> File.rm_rf!(root) end)

    a = Path.join([main, "worktrees", "feat-a"])
    File.mkdir_p!(a)
    {:ok, handle} = Storage.open(main, name: :seed)
    {:ok, _} = Storage.record_mouse(%{mouse_id: "ma", path: a, branch: "feat-a"})
    Storage.close(handle)

    stub(Herdr, :list_panes, fn @socket ->
      {:ok, [%{pane_id: @mouse_pane, cwd: a, agent: "claude", agent_status: "working"}]}
    end)

    stub(Herdr, :subscribe, fn @socket, _subs, _listener ->
      {:ok, spawn(fn -> receive do: (:stop -> :ok) end)}
    end)

    {:ok, main: main, a: a}
  end

  defp record_main(main) do
    {:ok, handle} = Storage.open(main, name: :seed)
    :ok = Storage.set_main_pane(@main_pane)
    Storage.close(handle)
  end

  defp open(main, opts \\ []) do
    opts =
      Keyword.merge(
        [main_checkout: main, herdr_socket: @socket, backstop_ms: 60_000, round_wait_ms: @wait],
        opts
      )

    pid = start_supervised!({House, opts})
    House.sync(pid)
    pid
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

  defp main_is(status, agent \\ "claude") do
    stub(Herdr, :pane, fn @socket, @main_pane ->
      {:ok, %{pane_id: @main_pane, cwd: "/main", agent: agent, agent_status: status}}
    end)
  end

  defp expect_prompts do
    test = self()

    stub(Herdr, :prompt, fn @socket, pane, text ->
      send(test, {:prompted, pane, text})
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
      assert_receive {:prompted, @main_pane, text}, @wait * 3
      assert text =~ "#1"
      assert text =~ "feat-a needs a decision"
      assert text =~ ~s("pick one")
      refute text =~ "more open"

      in_house(house, fn ->
        assert %Question{status: "sent", sent_at: %DateTime{}} = Storage.question(1)
      end)
    end

    test "questions landing inside the wait are counted in the first line", %{main: main, a: a} do
      main_is("idle")
      expect_prompts()
      house = open(main)

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

      assert_receive {:prompted, @main_pane, text}, @wait * 3
      assert text =~ ~s("first")
      assert text =~ "1 more open"
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
      assert_receive {:prompted, @main_pane, _}, @wait * 3
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

      assert_receive {:prompted, @main_pane, text}, @wait * 3
      assert text =~ "cannot tell whether you are idle"
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
      assert_receive {:prompted, @main_pane, first}, @wait * 3
      assert first =~ ~s("one")

      leave(main, a, "[worktree-status: needs-decision] two")
      # A second question from the same mouse would supersede the first, so
      # answer it before collecting the second.
      in_house(house, fn -> {:ok, _} = Storage.answer(1, "go") end)
      House.collect(house)

      # Nothing open, nothing out: a fresh round, so it waits again.
      refute_receive {:prompted, _, _}, div(@wait, 2)
      assert_receive {:prompted, @main_pane, second}, @wait * 3
      assert second =~ ~s("two")
    end

    test "while one is out, a newcomer waits", %{main: main, a: a} do
      main_is("idle")
      expect_prompts()
      house = open(main)

      b = Path.join([main, "worktrees", "feat-b"])
      File.mkdir_p!(b)

      leave(main, a, "[worktree-status: needs-decision] one")
      House.collect(house)
      assert_receive {:prompted, @main_pane, _}, @wait * 3

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
      assert_receive {:prompted, @main_pane, _}, @wait * 3

      leave(main, a, "[worktree-status: needs-decision] two")
      House.collect(house)

      assert_receive {:prompted, @main_pane, text}, @wait * 3
      assert text =~ ~s("two")

      in_house(house, fn ->
        assert Storage.question(1).status == "superseded"
        assert Storage.question(2).status == "sent"
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

      assert_receive :refused, @wait * 3
      in_house(house, fn -> assert Storage.question(1).status == "open" end)

      idle(house, @main_pane)
      assert_receive {:prompted, _}, @wait
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
      assert_receive {:prompted, @main_pane, _}, @wait * 3
    end

    test "a done report supersedes the mouse's earlier questions and is delivered as finished, closed the moment it is sent (ADR-0009)",
         %{main: main, a: a} do
      main_is("idle")
      expect_prompts()
      house = open(main)

      leave(main, a, "[worktree-status: needs-decision] one")
      House.collect(house)
      assert_receive {:prompted, @main_pane, _}, @wait * 3

      leave(main, a, "Merged it.\n[worktree-status: done]")
      House.collect(house)
      assert_receive {:prompted, @main_pane, text}, @wait * 3
      assert text =~ "#2"
      assert text =~ "finished"
      refute text =~ "whiska reply"

      in_house(house, fn ->
        assert Storage.question(1).status == "superseded"
        assert Storage.question(2).status == "closed"
        assert Storage.sent() == nil
      end)
    end

    test "a done report never holds the slot: the next question goes out behind it", %{
      main: main,
      a: a
    } do
      main_is("idle")
      expect_prompts()
      house = open(main)

      b = Path.join([main, "worktrees", "feat-b"])
      File.mkdir_p!(b)

      leave(main, a, "[worktree-status: done]")

      {:ok, _} =
        Doorstep.leave(main, %Entry{
          mouse_id: "mb",
          branch: "feat-b",
          worktree_root: b,
          stamped_at: DateTime.utc_now(),
          text: "[worktree-status: needs-decision] pick one"
        })

      House.collect(house)

      assert_receive {:prompted, @main_pane, first}, @wait * 3
      assert first =~ "finished"

      idle(house, @main_pane)
      assert_receive {:prompted, @main_pane, second}, @wait * 3
      assert second =~ "needs a decision"
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

      assert_receive {:prompted, _}, @wait * 4
    end
  end
end
