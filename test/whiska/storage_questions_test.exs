defmodule Whiska.StorageQuestionsTest do
  @moduledoc """
  What `whiska questions` and the statusline read: the waiting questions with
  their mouse loaded, and the orphaned ones shown apart.
  """
  use ExUnit.Case, async: true

  alias Whiska.Schema.Mouse
  alias Whiska.Schema.Question
  alias Whiska.Storage

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-sq-#{System.unique_integer([:positive])}")
    main = Path.join(root, "myrepo")
    File.mkdir_p!(Path.join(main, ".git"))
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, handle} = Storage.open(main, name: nil)
    on_exit(fn -> Storage.close(handle) end)
    {:ok, _} = Storage.record_mouse(%{mouse_id: "m1", path: "/w/a", branch: "feat-a"})
    {:ok, _} = Storage.record_mouse(%{mouse_id: "m2", path: "/w/b", branch: "feat-b"})
    :ok
  end

  defp ask(mouse, text, status, opts \\ []) do
    {:ok, q} =
      Storage.record_question(%{
        mouse_id: mouse,
        text: text,
        kind: Keyword.get(opts, :kind, "needs-decision"),
        status: status
      })

    q
  end

  describe "questions/0" do
    test "carries the mouse, so a listing shows a branch without a query per line" do
      ask("m1", "a", "open")
      ask("m2", "b", "sent")

      assert [
               %Question{mouse: %Mouse{branch: "feat-a"}},
               %Question{mouse: %Mouse{branch: "feat-b"}}
             ] =
               Storage.questions()
    end

    test "leaves out everything settled, including superseded (ADR-0037)" do
      open = ask("m1", "a", "open")
      ask("m1", "c", "answered")
      ask("m1", "d", "closed", kind: "done")
      ask("m2", "e", "orphaned")
      ask("m2", "f", "superseded")

      assert [%Question{id: id}] = Storage.questions()
      assert id == open.id
    end
  end

  describe "orphaned_questions/0" do
    test "lists only questions nothing can act on any more, by id, with the mouse" do
      ask("m1", "live", "open")
      o1 = ask("m1", "gone", "orphaned")
      o2 = ask("m2", "gone too", "orphaned")

      assert [%Question{id: id1, mouse: %{branch: "feat-a"}}, %Question{id: id2}] =
               Storage.orphaned_questions()

      assert {id1, id2} == {o1.id, o2.id}
    end
  end
end
