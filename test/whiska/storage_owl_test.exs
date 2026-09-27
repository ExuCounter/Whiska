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

    test "takes an explicit status, so a done report can be closed on arrival" do
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

    test "cascades the mouse's open questions to orphaned, and only those" do
      {:ok, open} = Storage.record_question(%{mouse_id: "m1", text: "a", kind: "needs-decision"})

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
  end

  describe "alive_mice/0" do
    test "lists mice that have not died, oldest first" do
      {:ok, _} = Storage.record_mouse(%{mouse_id: "m2", path: "/w/b", branch: "b"})
      {:ok, _} = Storage.mark_dead("m2")

      assert [%Mouse{mouse_id: "m1"}] = Storage.alive_mice()
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
