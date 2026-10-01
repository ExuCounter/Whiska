defmodule Whiska.StorageDeliveryTest do
  @moduledoc """
  What the delivery slice adds to storage: the house's main session, the
  delivery queue's reads and transitions (ADR-0008), answers keyed to a question
  id (ADR-0005), and superseding.
  """
  use ExUnit.Case, async: false

  alias Whiska.Schema.Mouse
  alias Whiska.Schema.Question
  alias Whiska.Storage

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-deliv-#{System.unique_integer([:positive])}")
    main = Path.join(root, "myrepo")
    File.mkdir_p!(Path.join(main, ".git"))
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, handle} = Storage.open(main)
    on_exit(fn -> Storage.close(handle) end)
    {:ok, _} = Storage.record_mouse(%{mouse_id: "m1", path: "/w/a", branch: "a"})
    {:ok, _} = Storage.record_mouse(%{mouse_id: "m2", path: "/w/b", branch: "b"})
    {:ok, main: main}
  end

  defp ask(mouse_id, text \\ "?", attrs \\ %{}) do
    {:ok, q} =
      Storage.record_question(
        Map.merge(%{mouse_id: mouse_id, text: text, kind: "needs-decision"}, attrs)
      )

    q
  end

  describe "the main session (ADR-0020)" do
    test "is nil until whiska start records it" do
      assert Storage.main_pane() == nil
    end

    test "is recorded and read back" do
      assert :ok = Storage.set_main_pane("w1:p2")
      assert Storage.main_pane() == "w1:p2"
    end

    test "recording again replaces it — one main session per house" do
      :ok = Storage.set_main_pane("w1:p2")
      :ok = Storage.set_main_pane("w1:p9")
      assert Storage.main_pane() == "w1:p9"
    end
  end

  describe "the queue (ADR-0008)" do
    test "next_open/0 is the oldest open question, or nil" do
      assert Storage.next_open() == nil
      first = ask("m1", "first")
      _second = ask("m2", "second")
      assert %Question{id: id} = Storage.next_open()
      assert id == first.id
    end

    test "next_open/0 skips anything that is not open" do
      ask("m1", "closed", %{kind: "done", status: "closed"})
      ask("m1", "orphaned", %{status: "orphaned"})
      sent = ask("m1", "sent")
      {:ok, _} = Storage.mark_sent(sent.id)
      assert Storage.next_open() == nil
    end

    test "next_done/0 is the oldest done report still waiting to be told, or nil" do
      assert Storage.next_done() == nil
      _decision = ask("m1", "first")
      report = ask("m2", "finished", %{kind: "done"})
      assert %Question{id: id} = Storage.next_done()
      assert id == report.id
    end

    test "next_done/0 skips a report already told, and anything that is not a report" do
      told = ask("m1", "told", %{kind: "done"})
      {:ok, _} = Storage.mark_sent(told.id)
      {:ok, _} = Storage.close_question(told.id)
      ask("m2", "unmarked", %{kind: "unmarked"})
      ask("m2", "worktree gone", %{kind: "done", status: "orphaned"})
      assert Storage.next_done() == nil
    end

    test "sent/0 is the question waiting for an answer, or nil" do
      assert Storage.sent() == nil
      q = ask("m1")
      {:ok, _} = Storage.mark_sent(q.id)
      assert %Question{status: "sent"} = Storage.sent()
    end

    test "sent/0 loads the mouse, so a reader can tell a dead one from a live one" do
      q = ask("m1")
      {:ok, _} = Storage.mark_sent(q.id)
      assert %Question{mouse: %Mouse{mouse_id: "m1", died_at: nil}} = Storage.sent()

      {:ok, _} = Storage.record_mouse(%{mouse_id: "m3", path: "/w/c", branch: "c"})
      other = ask("m3")
      {:ok, _} = Storage.mark_sent(other.id)
      {:ok, _} = Storage.answer(q.id, "done")
      {:ok, _} = Storage.mark_dead("m3")
      # Dead means orphaned now, so nothing is sent at all — the slot is free.
      assert Storage.sent() == nil
    end

    test "open_count/0 counts only open questions" do
      ask("m1")
      ask("m2")
      sent = ask("m1")
      {:ok, _} = Storage.mark_sent(sent.id)
      assert Storage.open_count() == 2
    end

    test "mark_sent/1 moves an open question to sent and stamps when" do
      q = ask("m1")
      assert {:ok, %Question{status: "sent", sent_at: %DateTime{}}} = Storage.mark_sent(q.id)
    end

    test "mark_sent/1 refuses a question that is not open" do
      q = ask("m1", "x", %{status: "orphaned"})
      assert {:error, :not_open} = Storage.mark_sent(q.id)
      assert {:error, :no_such_question} = Storage.mark_sent(999)
    end
  end

  describe "answer/2 (ADR-0005)" do
    test "records the answer against exactly that question and marks it answered" do
      a = ask("m1", "a?")
      b = ask("m1", "b?")
      {:ok, _} = Storage.mark_sent(a.id)

      assert {:ok, %Question{status: "answered", answer: "yes"}} = Storage.answer(a.id, "yes")
      assert Storage.question(b.id).status == "open"
    end

    test "an open question may be answered before it was ever delivered" do
      q = ask("m1")
      assert {:ok, %Question{status: "answered"}} = Storage.answer(q.id, "go")
    end

    test "refuses a question that is closed, orphaned, answered or missing" do
      q = ask("m1")
      {:ok, _} = Storage.answer(q.id, "once")
      assert {:error, :not_answerable} = Storage.answer(q.id, "twice")

      c = ask("m1", "x", %{kind: "done", status: "closed"})
      assert {:error, :not_answerable} = Storage.answer(c.id, "no")
      assert {:error, :no_such_question} = Storage.answer(999, "no")
    end
  end

  describe "close_question/1" do
    test "closes an open or sent question by hand, without an answer" do
      q = ask("m1")
      assert {:ok, %Question{status: "closed"}} = Storage.close_question(q.id)
    end

    test "closes an orphaned question too — the dead mouse's answer went by hand" do
      q = ask("m1", "x", %{status: "orphaned"})
      assert {:ok, %Question{status: "closed"}} = Storage.close_question(q.id)
    end

    test "refuses what is already settled" do
      q = ask("m1")
      {:ok, _} = Storage.answer(q.id, "done")
      assert {:error, :not_answerable} = Storage.close_question(q.id)
    end
  end

  describe "supersede_earlier/1" do
    test "a newer question from the same mouse supersedes its earlier open and sent ones" do
      old_open = ask("m1", "old open")
      old_sent = ask("m1", "old sent")
      {:ok, _} = Storage.mark_sent(old_sent.id)
      other = ask("m2", "other mouse")
      newest = ask("m1", "newest")

      assert {:ok, 2} = Storage.supersede_earlier(newest)

      assert Storage.question(old_open.id).status == "superseded"
      assert Storage.question(old_sent.id).status == "superseded"
      assert Storage.question(other.id).status == "open"
      assert Storage.question(newest.id).status == "open"
    end

    test "leaves answered, closed and orphaned history alone" do
      answered = ask("m1")
      {:ok, _} = Storage.answer(answered.id, "yes")
      closed = ask("m1", "x", %{kind: "done", status: "closed"})
      newest = ask("m1")

      assert {:ok, 0} = Storage.supersede_earlier(newest)
      assert Storage.question(answered.id).status == "answered"
      assert Storage.question(closed.id).status == "closed"
    end

    test "superseded is a status" do
      assert "superseded" in Question.statuses()
    end
  end

  describe "questions/0" do
    test "lists open and sent questions oldest first, nothing settled" do
      a = ask("m1", "a")
      b = ask("m2", "b")
      {:ok, _} = Storage.mark_sent(a.id)
      c = ask("m1", "c")
      {:ok, _} = Storage.answer(c.id, "x")

      assert [%Question{id: ida}, %Question{id: idb}] = Storage.questions()
      assert {ida, idb} == {a.id, b.id}
    end
  end
end
