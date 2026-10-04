defmodule Whiska.StorageTest do
  use ExUnit.Case, async: true

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
      {:ok, handle} = Storage.open(main, name: nil)
      on_exit(fn -> Storage.close(handle) end)

      assert File.exists?(Storage.database_path(main))
      # Both tables exist from day one, at their real schema (ADR-0030), so
      # nothing changes shape when the owl arrives.
      assert [] = Storage.all(Mouse)
      assert [] = Storage.all(Question)
    end

    test "is idempotent — the CLI reopens the same file on every invocation", %{main: main} do
      {:ok, handle} = Storage.open(main, name: nil)
      {:ok, _} = Storage.record_mouse(%{mouse_id: "m1", path: "/w/a", branch: "a"})
      Storage.close(handle)

      {:ok, handle2} = Storage.open(main, name: nil)
      on_exit(fn -> Storage.close(handle2) end)

      assert [%Mouse{mouse_id: "m1"}] = Storage.all(Mouse)
    end

    test "a file sqlite cannot open is an error at once, not after the pool gives up",
         %{main: main} do
      File.mkdir_p!(Storage.database_path(main))

      {micros, result} = :timer.tc(fn -> Storage.open(main, name: nil) end)

      assert {:error, _} = result
      assert micros < 500_000
    end

    test "a file that is not a database is an error at once, too", %{main: main} do
      File.mkdir_p!(Path.dirname(Storage.database_path(main)))
      File.write!(Storage.database_path(main), "not a database")

      {micros, result} = :timer.tc(fn -> Storage.open(main, name: nil) end)

      assert {:error, _} = result
      assert micros < 500_000
    end
  end

  describe "record_mouse/1" do
    setup %{main: main} do
      {:ok, handle} = Storage.open(main, name: nil)
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
      {:ok, handle} = Storage.open(main, name: nil)
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

  describe "shape/4 (ADR-0069)" do
    setup %{main: main} do
      {:ok, handle} = Storage.open(main)
      on_exit(fn -> Storage.close(handle) end)
      {:ok, _} = Storage.record_mouse(%{mouse_id: "m1", path: "/w/a", branch: "a"})
      :ok
    end

    test "a mouse minted without a shape says so" do
      mouse = Storage.mouse("m1")
      assert mouse.mode == "build"
      assert mouse.shaped_at == nil
      assert {mouse.model, mouse.effort, mouse.ran_on} == {nil, nil, nil}
    end

    test "records the mode, the model, the effort and when" do
      assert {:ok, _} = Storage.shape("m1", "sniff", "m-light", "xhigh")
      mouse = Storage.mouse("m1")
      assert {mouse.mode, mouse.model, mouse.effort} == {"sniff", "m-light", "xhigh"}
      assert %DateTime{} = mouse.shaped_at
    end

    test "a mouse on the person's own defaults has no model and no effort" do
      assert {:ok, _} = Storage.shape("m1", "build", nil, nil)
      assert {Storage.mouse("m1").model, Storage.mouse("m1").effort} == {nil, nil}
      assert Storage.mouse("m1").shaped_at
    end

    test "refuses a mode that is not build or sniff" do
      assert {:error, :invalid_mode} = Storage.shape("m1", "lurk", nil, nil)
    end
  end

  describe "the model a mouse actually ran on" do
    setup %{main: main} do
      {:ok, handle} = Storage.open(main)
      on_exit(fn -> Storage.close(handle) end)
      {:ok, _} = Storage.record_mouse(%{mouse_id: "m1", path: "/w/a", branch: "a"})
      :ok
    end

    test "is recorded beside the alias it was asked for" do
      {:ok, _} = Storage.shape("m1", "sniff", "m-light", nil)
      {:ok, _} = Storage.record_mouse(%{mouse_id: "m1", ran_on: "claude-m-light-5"})

      mouse = Storage.mouse("m1")
      assert {mouse.model, mouse.ran_on} == {"m-light", "claude-m-light-5"}
    end

    test "is forgotten when the mouse is shaped again, until a turn says" do
      {:ok, _} = Storage.record_mouse(%{mouse_id: "m1", ran_on: "claude-a-5"})
      {:ok, _} = Storage.shape("m1", "build", "m-heavy", nil)
      assert Storage.mouse("m1").ran_on == nil
    end

    test "follows the latest turn, and is not forgotten by a turn that did not say" do
      {:ok, _} = Storage.record_mouse(%{mouse_id: "m1", ran_on: "claude-a-5"})
      {:ok, _} = Storage.record_mouse(%{mouse_id: "m1", ran_on: "claude-b-5"})
      assert Storage.mouse("m1").ran_on == "claude-b-5"

      {:ok, _} = Storage.record_mouse(%{mouse_id: "m1", branch: "a", ran_on: nil})
      assert Storage.mouse("m1").ran_on == "claude-b-5"
    end
  end

  describe "a mode chosen by whiska mode counts as a shape (ADR-0069)" do
    setup %{main: main} do
      {:ok, handle} = Storage.open(main)
      on_exit(fn -> Storage.close(handle) end)
      {:ok, _} = Storage.record_mouse(%{mouse_id: "m1", path: "/w/a", branch: "a"})
      :ok
    end

    test "set_mode stamps shaped_at and leaves the model alone" do
      {:ok, _} = Storage.shape("m1", "sniff", "m-light", "low")
      {:ok, _} = Storage.set_mode("m1", "build")
      mouse = Storage.mouse("m1")
      assert {mouse.mode, mouse.model, mouse.effort} == {"build", "m-light", "low"}
      assert mouse.shaped_at

      {:ok, _} = Storage.record_mouse(%{mouse_id: "m2", path: "/w/b", branch: "b"})
      {:ok, _} = Storage.set_mode("m2", "build")
      assert Storage.mouse("m2").shaped_at
    end

    test "a mouse recorded before shapes existed is not blocked by them" do
      # Migration 7 grandfathers every mouse already in the house: it was
      # running as build when the rule arrived, and stopping it mid-task
      # would punish a spawn that could not have shaped it.
      alias Whiska.Migrations.V007Shape
      Ecto.Migrator.run(Whiska.Repo, [{7, V007Shape}], :down, all: true, log: false)

      Whiska.Repo.query!(
        "INSERT INTO mice (mouse_id, mode, created_at) VALUES ('old', 'build', '2026-09-01T00:00:00Z')"
      )

      Ecto.Migrator.run(Whiska.Repo, [{7, V007Shape}], :up, all: true, log: false)

      assert Storage.mouse("old").shaped_at
      assert Storage.mouse("m1").shaped_at
    end
  end

  describe "a mode changed by hand keeps what the mouse was shaped as (ADR-0074)" do
    setup %{main: main} do
      {:ok, handle} = Storage.open(main)
      on_exit(fn -> Storage.close(handle) end)
      {:ok, _} = Storage.record_mouse(%{mouse_id: "m1", path: "/w/a", branch: "a"})
      :ok
    end

    test "a shape records the mode its model and effort were chosen for" do
      {:ok, _} = Storage.shape("m1", "sniff", "m-heavy", "xhigh")
      assert Storage.mouse("m1").shaped_as == "sniff"
    end

    test "whiska mode moves the mode and leaves what it was shaped as alone" do
      {:ok, _} = Storage.shape("m1", "sniff", "m-heavy", "xhigh")
      {:ok, _} = Storage.set_mode("m1", "build")

      mouse = Storage.mouse("m1")
      assert {mouse.mode, mouse.shaped_as, mouse.model} == {"build", "sniff", "m-heavy"}
    end

    test "a mouse whose mode only whiska mode ever chose was shaped as nothing" do
      {:ok, _} = Storage.set_mode("m1", "build")
      assert Storage.mouse("m1").shaped_as == nil
    end

    test "shaping it again replaces what it was shaped as" do
      {:ok, _} = Storage.shape("m1", "sniff", "m-heavy", "xhigh")
      {:ok, _} = Storage.set_mode("m1", "build")
      {:ok, _} = Storage.shape("m1", "build", "m-light", "low")
      assert Storage.mouse("m1").shaped_as == "build"
    end
  end

  describe "set_mode/2 and mode/1 (ADR-0018)" do
    setup %{main: main} do
      {:ok, handle} = Storage.open(main, name: nil)
      on_exit(fn -> Storage.close(handle) end)
      {:ok, _} = Storage.record_mouse(%{mouse_id: "m1", path: "/w/a", branch: "a"})
      :ok
    end

    test "a mouse nobody shaped reads as unshaped, whatever is stored (ADR-0069)" do
      assert Storage.mode("m1") == {:ok, "unshaped"}
    end

    test "switches a mouse to sniff" do
      assert {:ok, mouse} = Storage.set_mode("m1", "sniff")
      assert mouse.mode == "sniff"
      assert Storage.mode("m1") == {:ok, "sniff"}
    end

    test "switches back to build" do
      {:ok, _} = Storage.set_mode("m1", "sniff")
      {:ok, _} = Storage.set_mode("m1", "build")

      assert Storage.mode("m1") == {:ok, "build"}
    end

    test "refuses a mode that is not build or sniff" do
      assert {:error, :invalid_mode} = Storage.set_mode("m1", "lurk")
      assert Storage.mode("m1") == {:ok, "unshaped"}
    end

    test "refuses to set the mode of a mouse that does not exist" do
      assert {:error, :no_such_mouse} = Storage.set_mode("ghost", "sniff")
    end

    test "routine bookkeeping never clobbers the mode" do
      # The hook calls record_mouse on every invocation to refresh the labels;
      # that must not quietly reset a sniff mouse to build.
      {:ok, _} = Storage.set_mode("m1", "sniff")
      {:ok, _} = Storage.record_mouse(%{mouse_id: "m1", path: "/w/moved", branch: "renamed"})

      assert Storage.mode("m1") == {:ok, "sniff"}
    end

    test "reports an unknown mouse rather than guessing a mode" do
      assert Storage.mode("ghost") == {:error, :no_such_mouse}
    end
  end

  describe "mark_removed/1 (ADR-0061)" do
    setup %{main: main} do
      {:ok, handle} = Storage.open(main, name: nil)
      on_exit(fn -> Storage.close(handle) end)
      {:ok, _} = Storage.record_mouse(%{mouse_id: "m1", path: "/w/a", branch: "a"})
      :ok
    end

    test "stamps the row rather than deleting it — ADR-0007 still holds for the record" do
      assert {:ok, mouse} = Storage.mark_removed("m1")
      assert %DateTime{} = mouse.removed_at
      assert %Mouse{removed_at: %DateTime{}} = Storage.mouse("m1")
    end

    test "is idempotent, so a second sweep over the same worktree changes nothing" do
      {:ok, first} = Storage.mark_removed("m1")
      {:ok, again} = Storage.mark_removed("m1")
      assert first.removed_at == again.removed_at
    end

    test "marks the mouse dead too: its pane went with its worktree" do
      {:ok, mouse} = Storage.mark_removed("m1")
      assert %DateTime{} = mouse.died_at
    end

    test "reports an unknown mouse rather than inventing one" do
      assert Storage.mark_removed("ghost") == {:error, :no_such_mouse}
    end
  end
end
