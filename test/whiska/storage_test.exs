defmodule Whiska.StorageTest do
  use ExUnit.Case, async: false

  alias Whiska.Schema.Mouse
  alias Whiska.Schema.Question
  alias Whiska.Storage

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-storage-#{System.unique_integer([:positive])}")
    main = Path.join(root, "myrepo")
    File.mkdir_p!(Path.join(main, ".git"))
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, main: main}
  end

  describe "database_path/1" do
    test "lives in the shared git dir so every worktree sees one house", %{main: main} do
      assert Storage.database_path(main) == Path.join(main, ".git/whiska/whiska.db")
    end
  end

  describe "open/1" do
    test "creates the database and migrates it", %{main: main} do
      {:ok, handle} = Storage.open(main)
      on_exit(fn -> Storage.close(handle) end)

      assert File.exists?(Storage.database_path(main))
      # Both tables exist from day one, at their real schema (ADR-0030), so
      # nothing changes shape when the owl arrives.
      assert [] = Storage.all(Mouse)
      assert [] = Storage.all(Question)
    end

    test "is idempotent — the CLI reopens the same file on every invocation", %{main: main} do
      {:ok, handle} = Storage.open(main)
      {:ok, _} = Storage.record_mouse(%{mouse_id: "m1", path: "/w/a", branch: "a"})
      Storage.close(handle)

      {:ok, handle2} = Storage.open(main)
      on_exit(fn -> Storage.close(handle2) end)

      assert [%Mouse{mouse_id: "m1"}] = Storage.all(Mouse)
    end
  end

  describe "record_mouse/1" do
    setup %{main: main} do
      {:ok, handle} = Storage.open(main)
      on_exit(fn -> Storage.close(handle) end)
      :ok
    end

    test "inserts a mouse keyed by mouse_id, with created_at" do
      assert {:ok, mouse} = Storage.record_mouse(%{mouse_id: "m1", path: "/w/a", branch: "a"})

      assert mouse.mouse_id == "m1"
      assert mouse.path == "/w/a"
      assert mouse.branch == "a"
      assert %DateTime{} = mouse.created_at
    end

    test "defaults mode to build (ADR-0018)" do
      assert {:ok, mouse} = Storage.record_mouse(%{mouse_id: "m1", path: "/w/a", branch: "a"})
      assert mouse.mode == "build"
    end

    test "leaves pane unset — v0.0.1 never talks to herdr" do
      assert {:ok, mouse} = Storage.record_mouse(%{mouse_id: "m1", path: "/w/a", branch: "a"})
      assert is_nil(mouse.pane)
    end

    test "refreshes path and branch, which are live labels not the key (ADR-0002)" do
      {:ok, first} = Storage.record_mouse(%{mouse_id: "m1", path: "/w/old", branch: "old"})
      {:ok, again} = Storage.record_mouse(%{mouse_id: "m1", path: "/w/new", branch: "new"})

      assert again.path == "/w/new"
      assert again.branch == "new"
      # Same row, not a second one: identity survived the relabelling.
      assert length(Storage.all(Mouse)) == 1
      assert again.created_at == first.created_at
    end

    test "keeps distinct mice apart" do
      {:ok, _} = Storage.record_mouse(%{mouse_id: "m1", path: "/w/a", branch: "a"})
      {:ok, _} = Storage.record_mouse(%{mouse_id: "m2", path: "/w/b", branch: "b"})

      assert length(Storage.all(Mouse)) == 2
    end
  end

  describe "the Question table" do
    setup %{main: main} do
      {:ok, handle} = Storage.open(main)
      on_exit(fn -> Storage.close(handle) end)
      {:ok, _} = Storage.record_mouse(%{mouse_id: "m1", path: "/w/a", branch: "a"})
      :ok
    end

    test "carries its real schema even though v0.0.1 writes nothing into it" do
      # ADR-0030: v0.0.1's one rule denies rather than asks, so there is no rule
      # that writes a meaningful row here yet. The shape is still final.
      question =
        Whiska.Repo.insert!(%Question{
          mouse_id: "m1",
          text: "mouse wants to push branch a — approve?",
          kind: "needs-decision",
          status: "open",
          asked_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      assert is_integer(question.id)
      assert is_nil(question.answer)
      assert [^question] = Storage.all(Question)
    end

    test "ids are plain incrementing numbers, global within this house" do
      asked = DateTime.utc_now() |> DateTime.truncate(:second)

      a =
        Whiska.Repo.insert!(%Question{
          mouse_id: "m1",
          text: "a",
          kind: "needs-decision",
          status: "open",
          asked_at: asked
        })

      b =
        Whiska.Repo.insert!(%Question{
          mouse_id: "m1",
          text: "b",
          kind: "done",
          status: "open",
          asked_at: asked
        })

      assert b.id == a.id + 1
    end

    test "refuses a question pointing at a mouse that does not exist" do
      asked = DateTime.utc_now() |> DateTime.truncate(:second)

      assert_raise Ecto.ConstraintError, fn ->
        Whiska.Repo.insert!(%Question{
          mouse_id: "ghost",
          text: "x",
          kind: "done",
          status: "open",
          asked_at: asked
        })
      end
    end
  end
end
