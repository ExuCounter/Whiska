defmodule Whiska.StorageOwlTest do
  @moduledoc """
  What the owl slice adds to storage: questions written on collection, mice
  marked dead, panes recorded, and one house per Repo instance.
  """
  use ExUnit.Case, async: false

  alias Whiska.Schema.Mouse
  alias Whiska.Schema.Question
  alias Whiska.Storage

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-owl-#{System.unique_integer([:positive])}")
    main = Path.join(root, "myrepo")
    File.mkdir_p!(Path.join(main, ".git"))
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, handle} = Storage.open(main)
    on_exit(fn -> Storage.close(handle) end)
    {:ok, _} = Storage.record_mouse(%{mouse_id: "m1", path: "/w/a", branch: "a"})
    {:ok, main: main, root: root}
  end

  describe "the schema after V002" do
    test "a question may be unmarked (ADR-0009) and closed (a done report)" do
      assert "unmarked" in Question.kinds()
      assert "closed" in Question.statuses()
    end

    test "a mouse starts alive" do
      assert [%Mouse{died_at: nil}] = Storage.all(Mouse)
    end
  end

  describe "record_question/1" do
    test "inserts an open question for a mouse" do
      assert {:ok, q} =
               Storage.record_question(%{mouse_id: "m1", text: "push?", kind: "needs-decision"})

      assert q.status == "open"
      assert %DateTime{} = q.asked_at
      assert [%Question{id: id}] = Storage.all(Question)
      assert id == q.id
    end

    test "takes an explicit status, so an entry with no worktree can be orphaned on arrival" do
      assert {:ok, q} =
               Storage.record_question(%{
                 mouse_id: "m1",
                 text: "finished",
                 kind: "done",
                 status: "closed"
               })

      assert q.status == "closed"
    end

    test "refuses an unknown kind or status rather than storing nonsense" do
      assert {:error, _} = Storage.record_question(%{mouse_id: "m1", text: "x", kind: "shrug"})

      assert {:error, _} =
               Storage.record_question(%{
                 mouse_id: "m1",
                 text: "x",
                 kind: "done",
                 status: "vanished"
               })
    end
  end

  describe "set_pane/2" do
    test "records the pane herdr reported for a mouse (ADR-0006)" do
      assert {:ok, %Mouse{pane: "w1:p2"}} = Storage.set_pane("m1", "w1:p2")
      assert Storage.mouse("m1").pane == "w1:p2"
    end

    test "a pane appearing again on a dead mouse's worktree brings it back" do
      {:ok, _} = Storage.mark_dead("m1")
      assert {:ok, %Mouse{died_at: nil, pane: "w1:p9"}} = Storage.set_pane("m1", "w1:p9")
    end

    test "refuses an unknown mouse" do
      assert {:error, :no_such_mouse} = Storage.set_pane("ghost", "w1:p2")
    end
  end

  describe "mark_dead/1 (ADR-0026, ADR-0007)" do
    test "stamps died_at and keeps the row" do
      assert {:ok, %Mouse{died_at: %DateTime{}}} = Storage.mark_dead("m1")
      assert [%Mouse{mouse_id: "m1"}] = Storage.all(Mouse)
    end

    test "cascades the mouse's open and sent questions to orphaned, and only those" do
      {:ok, open} = Storage.record_question(%{mouse_id: "m1", text: "a", kind: "needs-decision"})

      # A sent question whose mouse is dead can never be answered — there is
      # nowhere to reply — and it would hold ADR-0008's one delivery slot
      # forever. It orphans with the rest.
      {:ok, out} = Storage.record_question(%{mouse_id: "m1", text: "d", kind: "needs-decision"})
      {:ok, _} = Storage.mark_sent(out.id)

      {:ok, answered} =
        Storage.record_question(%{
          mouse_id: "m1",
          text: "b",
          kind: "needs-decision",
          status: "answered"
        })

      {:ok, _} = Storage.record_mouse(%{mouse_id: "m2", path: "/w/b", branch: "b"})
      {:ok, other} = Storage.record_question(%{mouse_id: "m2", text: "c", kind: "needs-decision"})

      {:ok, _} = Storage.mark_dead("m1")

      assert Storage.question(open.id).status == "orphaned"
      assert Storage.question(out.id).status == "orphaned"
      assert Storage.question(answered.id).status == "answered"
      assert Storage.question(other.id).status == "open"
    end

    test "is idempotent — the first death date stands" do
      {:ok, first} = Storage.mark_dead("m1")
      {:ok, again} = Storage.mark_dead("m1")
      assert again.died_at == first.died_at
    end

    test "refuses an unknown mouse" do
      assert {:error, :no_such_mouse} = Storage.mark_dead("ghost")
    end

    # The cascade has to run on a mouse already marked dead, not only on the
    # death itself. A question collected after the death arrives `open`, is
    # delivered, and then holds ADR-0008's one slot with nothing alive behind
    # it — the wedge this is here to stop.
    test "releases a question that arrived after the death" do
      {:ok, _} = Storage.mark_dead("m1")
      late = ask("m1")
      {:ok, _} = Storage.mark_sent(late.id)

      {:ok, _} = Storage.mark_dead("m1")

      assert Storage.question(late.id).status == "orphaned"
    end
  end

  # Nothing that cannot be answered may hold the one delivery slot (ADR-0057):
  # a dead mouse's sent question, and a question from a record that no longer
  # stands for a worktree of this house.
  describe "release_unanswerable/0 (ADR-0057)" do
    test "releases a dead mouse's open and sent questions" do
      open = ask("m1")
      sent = ask("m1")
      {:ok, _} = Storage.mark_sent(sent.id)
      {:ok, _} = Storage.mark_dead("m1")
      # Put one back by hand, as a collection after the death would.
      late = ask("m1")

      # The death itself released the first two; this catches the late arrival.
      assert [%Question{id: id}] = Storage.release_unanswerable()
      assert id == late.id

      assert Storage.question(open.id).status == "orphaned"
      assert Storage.question(sent.id).status == "orphaned"
      assert Storage.question(late.id).status == "orphaned"
    end

    test "releases a question from a record that no longer stands for a worktree" do
      {:ok, _} =
        Storage.record_mouse(%{
          mouse_id: "phantom",
          path: "/w/quality",
          branch: "quality",
          created_at: ~U[2026-09-29 10:00:00Z]
        })

      {:ok, _} =
        Storage.record_mouse(%{
          mouse_id: "real",
          path: "/w/quality/QUAL-350",
          branch: "quality/QUAL-350",
          created_at: ~U[2026-09-29 11:00:00Z]
        })

      wedged = ask("phantom")
      {:ok, _} = Storage.mark_sent(wedged.id)
      theirs = ask("real")

      assert [%Question{}] = Storage.release_unanswerable()

      assert Storage.question(wedged.id).status == "orphaned"
      assert Storage.question(theirs.id).status == "open"
    end

    # A finished line never takes the slot and never holds it (ADR-0008, note of
    # 2026-10-01), so it is not this sweep's business: releasing it would be the
    # branch finishing silently.
    test "leaves a done report alone when it arrives after its mouse died" do
      {:ok, _} = Storage.mark_dead("m1")
      report = ask("m1", %{kind: "done"})

      assert [] = Storage.release_unanswerable()
      assert Storage.question(report.id).status == "open"
    end

    test "leaves a live mouse's questions and everything already settled alone" do
      open = ask("m1")
      sent = ask("m1")
      {:ok, _} = Storage.mark_sent(sent.id)
      answered = ask("m1", %{status: "answered"})

      assert [] = Storage.release_unanswerable()

      assert Storage.question(open.id).status == "open"
      assert Storage.question(sent.id).status == "sent"
      assert Storage.question(answered.id).status == "answered"
    end
  end

  defp ask(mouse_id, attrs \\ %{}) do
    {:ok, q} =
      Storage.record_question(
        Map.merge(%{mouse_id: mouse_id, text: "?", kind: "needs-decision"}, attrs)
      )

    q
  end

  # A branch that landed answered everything its mouse was still waiting on:
  # the merge was the answer (ADR-0063). Settled is kept apart from orphaned so
  # that an orphan still means something went wrong.
  describe "mark_landed/1 (ADR-0063)" do
    test "stamps landed_at and keeps the first date on a second sweep" do
      assert {:ok, %Mouse{landed_at: %DateTime{}} = first} = Storage.mark_landed("m1")
      assert {:ok, again} = Storage.mark_landed("m1")
      assert again.landed_at == first.landed_at
    end

    test "settles what this mouse already had orphaned, and nothing of another's" do
      mine = ask("m1")
      {:ok, _} = Storage.mark_dead("m1")
      assert Storage.question(mine.id).status == "orphaned"

      {:ok, _} = Storage.record_mouse(%{mouse_id: "m2", path: "/w/b", branch: "b"})
      theirs = ask("m2")
      {:ok, _} = Storage.mark_dead("m2")

      {:ok, _} = Storage.mark_landed("m1")

      assert Storage.question(mine.id).status == "settled"
      assert Storage.question(theirs.id).status == "orphaned"
    end

    test "leaves a live mouse's open question answerable — landing is not an answer yet" do
      open = ask("m1")
      {:ok, _} = Storage.mark_landed("m1")
      assert Storage.question(open.id).status == "open"
    end

    test "refuses an unknown mouse" do
      assert {:error, :no_such_mouse} = Storage.mark_landed("ghost")
    end
  end

  describe "a landed mouse's cascade (ADR-0063)" do
    test "mark_dead/1 settles what it left waiting rather than orphaning it" do
      open = ask("m1")
      sent = ask("m1")
      {:ok, _} = Storage.mark_sent(sent.id)
      {:ok, _} = Storage.mark_landed("m1")

      {:ok, _} = Storage.mark_dead("m1")

      assert Storage.question(open.id).status == "settled"
      assert Storage.question(sent.id).status == "settled"
    end

    test "release_unanswerable/0 settles a landed mouse's and orphans an abandoned one's" do
      {:ok, _} = Storage.record_mouse(%{mouse_id: "m2", path: "/w/b", branch: "b"})
      {:ok, _} = Storage.mark_landed("m1")
      {:ok, _} = Storage.mark_dead("m1")
      {:ok, _} = Storage.mark_dead("m2")

      landed = ask("m1")
      abandoned = ask("m2")

      assert [_, _] = Storage.release_unanswerable()

      assert Storage.question(landed.id).status == "settled"
      assert Storage.question(abandoned.id).status == "orphaned"
    end

    test "a settled question is neither waiting nor orphaned, so neither count moves" do
      q = ask("m1")
      {:ok, _} = Storage.mark_landed("m1")
      {:ok, _} = Storage.mark_dead("m1")

      assert Storage.question(q.id).status == "settled"
      assert [] = Storage.questions()
      assert [] = Storage.orphaned_questions()
    end
  end

  describe "alive_mice/0" do
    test "lists mice that have not died, oldest first" do
      {:ok, _} = Storage.record_mouse(%{mouse_id: "m2", path: "/w/b", branch: "b"})
      {:ok, _} = Storage.mark_dead("m2")

      assert [%Mouse{mouse_id: "m1"}] = Storage.alive_mice()
    end

    test "a record whose worktree holds another mouse's worktree is stale" do
      # A branch with a slash nests on disk, and `worktrees/feat` owns nothing
      # (ADR-0030 note). The record made before that was understood points at it.
      {:ok, _} = Storage.record_mouse(%{mouse_id: "stale", path: "/w/feat", branch: "feat"})

      {:ok, _} =
        Storage.record_mouse(%{
          mouse_id: "real",
          path: "/w/feat/csv-data-page",
          branch: "feat/csv-data-page"
        })

      assert ["m1", "real"] = Enum.map(Storage.alive_mice(), & &1.mouse_id) |> Enum.sort()
    end

    test "the newer record for a worktree supersedes the older one" do
      {:ok, _} =
        Storage.record_mouse(%{
          mouse_id: "old",
          path: "/w/b",
          branch: "b",
          created_at: ~U[2026-09-29 10:00:00Z]
        })

      {:ok, _} =
        Storage.record_mouse(%{
          mouse_id: "new",
          path: "/w/b",
          branch: "b",
          created_at: ~U[2026-09-30 10:00:00Z]
        })

      assert ["m1", "new"] = Enum.map(Storage.alive_mice(), & &1.mouse_id) |> Enum.sort()
    end

    test "a branch takes back the folder a nested one left behind" do
      # `feat/checkout-form` is dropped and its branch deleted, which frees the
      # name `feat` for a branch of its own. The old record is history.
      {:ok, _} =
        Storage.record_mouse(%{
          mouse_id: "mnested",
          path: "/w/feat/checkout-form",
          branch: "feat/checkout-form",
          created_at: ~U[2026-09-01 10:00:00Z]
        })

      {:ok, _} = Storage.mark_dead("mnested")

      {:ok, _} =
        Storage.record_mouse(%{
          mouse_id: "mfeat",
          path: "/w/feat",
          branch: "feat",
          created_at: ~U[2026-10-01 10:00:00Z]
        })

      assert ["m1", "mfeat"] = Enum.map(Storage.alive_mice(), & &1.mouse_id) |> Enum.sort()
    end

    test "two records made for one worktree in the same second leave one row" do
      at = ~U[2026-09-29 10:00:00Z]

      for id <- ["mz", "my"] do
        {:ok, _} =
          Storage.record_mouse(%{mouse_id: id, path: "/w/b", branch: "b", created_at: at})
      end

      assert ["m1", "mz"] = Enum.map(Storage.alive_mice(), & &1.mouse_id) |> Enum.sort()
    end
  end

  describe "current_mice/0" do
    test "keeps a dead record, and drops a stale one whatever its state" do
      {:ok, _} = Storage.record_mouse(%{mouse_id: "stale", path: "/w/feat", branch: "feat"})

      {:ok, _} =
        Storage.record_mouse(%{mouse_id: "real", path: "/w/feat/page", branch: "feat/page"})

      {:ok, _} = Storage.mark_dead("real")

      assert ["m1", "real"] = Enum.map(Storage.current_mice(), & &1.mouse_id) |> Enum.sort()
    end
  end

  describe "one Repo instance per house" do
    test "two houses can be open in one VM without sharing a connection", %{root: root} do
      other = Path.join(root, "other")
      File.mkdir_p!(Path.join(other, ".git"))

      {:ok, handle} = Storage.open(other, name: :other_house)
      on_exit(fn -> Storage.close(handle) end)

      # open/2 pointed this process at the other house; it is empty.
      assert [] = Storage.all(Mouse)

      Storage.point_at(Whiska.Repo)
      assert [%Mouse{mouse_id: "m1"}] = Storage.all(Mouse)
    end
  end
end
