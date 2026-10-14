defmodule Whiska.StorageDeliveryTest do
  @moduledoc """
  What the delivery slice adds to storage: the house's main session, the
  delivery queue's reads and transitions (ADR-0008), answers keyed to a question
  id (ADR-0005), and superseding.
  """
  use ExUnit.Case, async: true

  alias Whiska.Delivery.Mode
  alias Whiska.Schema.Mouse
  alias Whiska.Schema.Question
  alias Whiska.Storage

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-deliv-#{System.unique_integer([:positive])}")
    main = Path.join(root, "myrepo")
    File.mkdir_p!(Path.join(main, ".git"))
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, handle} = Storage.open(main, name: nil)
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

    test "an answer is stamped with when it was given" do
      q = ask("m1")
      before = DateTime.utc_now() |> DateTime.truncate(:second)
      {:ok, _} = Storage.answer(q.id, "go")
      answered_at = Storage.question(q.id).answered_at
      assert DateTime.compare(answered_at, before) != :lt
      assert DateTime.compare(answered_at, DateTime.utc_now()) != :gt
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

    test "the newer question inherits the slot from a sent one, and passes it down a chain" do
      sent = ask("m1", "out")
      {:ok, _} = Storage.mark_sent(sent.id)
      heir = ask("m1", "follow-up")
      {:ok, _} = Storage.supersede_earlier(heir)
      next = ask("m1", "another")
      {:ok, _} = Storage.supersede_earlier(next)

      assert Storage.question(heir.id).keeps_slot
      assert Storage.question(next.id).keeps_slot
    end

    test "superseding a question still only queued passes no slot" do
      queued = ask("m1", "queued")
      newest = ask("m1", "newest")

      {:ok, 1} = Storage.supersede_earlier(newest)
      refute Storage.question(newest.id).keeps_slot
    end

    test "a newer question that arrived settled or orphaned inherits nothing" do
      sent = ask("m1", "out")
      {:ok, _} = Storage.mark_sent(sent.id)
      gone = ask("m1", "worktree gone", %{status: "orphaned"})

      {:ok, 1} = Storage.supersede_earlier(gone)
      refute Storage.question(gone.id).keeps_slot
    end

    test "the owl's own question neither supersedes a mouse's nor is superseded by one" do
      sent = ask("m1", "which way?")
      {:ok, _} = Storage.mark_sent(sent.id)
      owl = ask("m1", "Drop?", %{asked_by: "owl"})

      assert {:ok, 0} = Storage.supersede_earlier(owl)
      assert Storage.question(sent.id).status == "sent"
      refute Storage.question(owl.id).keeps_slot

      newest = ask("m1", "another")
      assert {:ok, 1} = Storage.supersede_earlier(newest)
      assert Storage.question(owl.id).status == "open"
      assert Storage.question(sent.id).status == "superseded"
    end

    test "an answer is still handed over after the owl asks something of its mouse" do
      q = ask("m1", "which way?")
      {:ok, _} = Storage.answer(q.id, "left")
      ask("m1", "Drop?", %{asked_by: "owl"})

      assert [%Question{id: id}] = Storage.chased()
      assert id == q.id
    end

    test "superseded is a status" do
      assert "superseded" in Question.statuses()
    end
  end

  describe "supersede_for_letter/2" do
    defp letter(mouse_id),
      do: Storage.supersede_for_letter(mouse_id, Storage.waiting_ids(mouse_id))

    test "retires the mouse's own open and sent questions, and leaves the owl's" do
      queued = ask("m1", "queued", %{kind: "done"})
      sent = ask("m1", "out")
      {:ok, _} = Storage.mark_sent(sent.id)
      owl = ask("m1", "Drop?", %{asked_by: "owl"})
      other = ask("m2", "other mouse")

      assert Storage.waiting_ids("m1") == [queued.id, sent.id]
      assert {:ok, [queued.id, sent.id]} == letter("m1")

      assert Storage.question(queued.id).status == "superseded"
      assert Storage.question(sent.id).status == "superseded"
      assert Storage.question(owl.id).status == "open"
      assert Storage.question(other.id).status == "open"
    end

    test "retires only what the line was decided on, not a question collected since" do
      sent = ask("m1", "out")
      {:ok, _} = Storage.mark_sent(sent.id)
      ids = Storage.waiting_ids("m1")
      since = ask("m1", "collected while the line was typed")

      assert {:ok, [sent.id]} == Storage.supersede_for_letter("m1", ids)
      assert Storage.question(since.id).status == "open"
    end

    test "the mouse's next message goes next once the slot is free, once" do
      sent = ask("m1", "out")
      {:ok, _} = Storage.mark_sent(sent.id)
      older = ask("m2", "waiting longer")
      {:ok, [_]} = letter("m1")

      owl = ask("m1", "Drop?", %{asked_by: "owl"})
      {:ok, 0} = Storage.supersede_earlier(owl)
      refute Storage.question(owl.id).goes_next

      reply = ask("m1", "after the letter")
      {:ok, 0} = Storage.supersede_earlier(reply)
      assert Storage.question(reply.id).goes_next
      refute Storage.question(reply.id).keeps_slot
      assert Mode.next(Storage.questions(), Mode.none()).id == reply.id
      refute Mode.next(Storage.questions(), Mode.none()).id == older.id

      {:ok, _} = Storage.answer(reply.id, "fine")
      later = ask("m1", "a later turn")
      {:ok, 0} = Storage.supersede_earlier(later)
      refute Storage.question(later.id).goes_next
    end

    test "the reply waits behind another branch's heir, then goes ahead of the rest" do
      {:ok, _} = Storage.record_mouse(%{mouse_id: "m3", path: "/w/c", branch: "c"})
      a = ask("m1", "a's question")
      {:ok, _} = Storage.mark_sent(a.id)
      {:ok, [_]} = letter("m1")

      oldest = ask("m3", "queued all along")
      b = ask("m2", "b's question")
      {:ok, _} = Storage.mark_sent(b.id)

      a2 = ask("m1", "a's reply")
      {:ok, 0} = Storage.supersede_earlier(a2)
      b2 = ask("m2", "b moved on")
      {:ok, 1} = Storage.supersede_earlier(b2)

      assert Mode.next(Storage.questions(), Mode.none()).id == b2.id
      {:ok, _} = Storage.mark_sent(b2.id)
      {:ok, _} = Storage.answer(b2.id, "done with b")
      assert Mode.next(Storage.questions(), Mode.none()).id == a2.id
      refute Mode.next(Storage.questions(), Mode.none()).id == oldest.id
    end

    test "a reply not yet typed passes its place to the mouse's newer message, or to a letter's" do
      a = ask("m1", "out")
      {:ok, _} = Storage.mark_sent(a.id)
      {:ok, [_]} = letter("m1")
      a2 = ask("m1", "reply")
      {:ok, 0} = Storage.supersede_earlier(a2)

      a3 = ask("m1", "and another")
      {:ok, 1} = Storage.supersede_earlier(a3)
      assert Storage.question(a3.id).goes_next

      {:ok, [_]} = letter("m1")
      a4 = ask("m1", "after a second letter")
      {:ok, 0} = Storage.supersede_earlier(a4)
      assert Storage.question(a4.id).goes_next
    end

    test "a question the letter retired before the owl got to it leaves the place to the reply" do
      sent = ask("m1", "out")
      {:ok, _} = Storage.mark_sent(sent.id)
      # Recorded by the owl, then the letter lands before its supersede runs.
      raced = ask("m1", "recorded")
      {:ok, [_, _]} = letter("m1")
      {:ok, _} = Storage.supersede_earlier(raced)
      refute Storage.question(raced.id).goes_next

      reply = ask("m1", "after the letter")
      {:ok, 0} = Storage.supersede_earlier(reply)
      assert Storage.question(reply.id).goes_next
    end

    test "a letter to a mouse whose question was only queued gives no place" do
      ask("m1", "queued")
      {:ok, [_]} = letter("m1")

      reply = ask("m1", "after the letter")
      {:ok, 0} = Storage.supersede_earlier(reply)
      refute Storage.question(reply.id).goes_next
    end

    test "a letter to a mouse with nothing out retires nothing" do
      assert {:ok, []} = letter("m1")

      reply = ask("m1", "after the letter")
      {:ok, 0} = Storage.supersede_earlier(reply)
      refute Storage.question(reply.id).goes_next
    end

    test "the mouse's death takes the place its next message would have had" do
      sent = ask("m1", "out")
      {:ok, _} = Storage.mark_sent(sent.id)
      {:ok, [_]} = letter("m1")
      {:ok, _} = Storage.mark_dead("m1")

      refute Storage.mouse("m1").reply_goes_next
    end
  end

  describe "waiting_ids/1" do
    test "are the mouse's own open or sent questions, never the owl's" do
      assert Storage.waiting_ids("m1") == []
      ask("m1", "Drop?", %{asked_by: "owl"})
      assert Storage.waiting_ids("m1") == []
      q = ask("m1", "which way?")
      assert Storage.waiting_ids("m1") == [q.id]
      {:ok, _} = Storage.answer(q.id, "left")
      assert Storage.waiting_ids("m1") == []
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
