defmodule Whiska.StorageTest do
  use ExUnit.Case, async: true

  alias Whiska.Schema.Mouse
  alias Whiska.Schema.Question
  alias Whiska.Storage

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-storage-#{Whiska.Test.Unique.id()}")
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

  describe "the suite's house guard" do
    # A mouse's `mix test` once opened the main checkout's own house and
    # applied the branch's migrations to it. Under test, a house outside the
    # run's temp folder is refused before anything is created.
    test "refuses a house outside the temp folder, and creates nothing there" do
      main =
        Path.join(
          Whiska.Test.RealHome.path(),
          "whiska-guard-#{System.unique_integer([:positive])}"
        )

      on_exit(fn -> File.rm_rf!(main) end)

      assert {:error, {:outside_test_area, path}} =
               Whiska.Test.HouseGuard.expect_refusal(fn -> Storage.open(main, name: nil) end)

      assert path == Storage.database_path(main)
      refute File.exists?(main)
    end
  end

  describe "the suite's house guard, on a resolved path" do
    test "allows a house under the temp folder as git names it, symlinks resolved", %{main: main} do
      {resolved, 0} = System.cmd("pwd", ["-P"], cd: main)

      assert :ok = Whiska.Test.HouseGuard.check(Storage.database_path(String.trim(resolved)))
    end
  end

  describe "the v021 migration" do
    test "closes every report still open or sent, and counts each one hooted", %{main: main} do
      {:ok, handle} = Storage.open(main, name: nil)
      on_exit(fn -> Storage.close(handle) end)
      v021 = [{21, Whiska.Migrations.V021ReportHooted}]
      Ecto.Migrator.run(Whiska.Repo, v021, :down, all: true, log: false)

      {:ok, _} = Storage.record_mouse(%{mouse_id: "m1", path: "/w/a", branch: "a"})

      for {status, kind, sent_at} <- [
            {"open", "done", nil},
            {"sent", "done", "2026-10-13T09:30:00Z"},
            {"closed", "done", "2026-10-12T08:00:00Z"},
            {"open", "needs-decision", nil}
          ] do
        Whiska.Repo.query!(
          "INSERT INTO questions (mouse_id, text, kind, status, asked_at, sent_at) " <>
            "VALUES ('m1', 'x', ?, ?, '2026-10-13T09:00:00Z', ?)",
          [kind, status, sent_at]
        )
      end

      Ecto.Migrator.run(Whiska.Repo, v021, :up, all: true, log: false)

      assert [
               %{status: "closed", hooted_at: ~U[2026-10-13 09:00:00Z]},
               %{status: "closed", hooted_at: ~U[2026-10-13 09:30:00Z]},
               %{status: "closed", hooted_at: ~U[2026-10-12 08:00:00Z]},
               %{status: "open", hooted_at: nil}
             ] = Storage.all(Question) |> Enum.sort_by(& &1.id)
    end
  end

  describe "the v023 migration" do
    test "counts every report already kept as typed, and leaves questions alone", %{main: main} do
      {:ok, handle} = Storage.open(main, name: nil)
      on_exit(fn -> Storage.close(handle) end)
      v023 = [{23, Whiska.Migrations.V023ReportTyped}]
      Ecto.Migrator.run(Whiska.Repo, v023, :down, all: true, log: false)

      {:ok, _} = Storage.record_mouse(%{mouse_id: "m1", path: "/w/a", branch: "a"})

      for {kind, sent_at, hooted_at} <- [
            {"done", "2026-10-13T09:30:00Z", "2026-10-13T09:40:00Z"},
            {"done", nil, "2026-10-14T10:00:00Z"},
            {"done", nil, nil},
            {"needs-decision", "2026-10-13T09:30:00Z", nil}
          ] do
        Whiska.Repo.query!(
          "INSERT INTO questions (mouse_id, text, kind, status, asked_at, sent_at, hooted_at) " <>
            "VALUES ('m1', 'x', ?, 'closed', '2026-10-13T09:00:00Z', ?, ?)",
          [kind, sent_at, hooted_at]
        )
      end

      Ecto.Migrator.run(Whiska.Repo, v023, :up, all: true, log: false)

      assert [
               %{typed_at: ~U[2026-10-13 09:30:00Z]},
               %{typed_at: ~U[2026-10-14 10:00:00Z]},
               %{typed_at: ~U[2026-10-13 09:00:00Z]},
               %{typed_at: nil}
             ] = Storage.all(Question) |> Enum.sort_by(& &1.id)
    end
  end

  describe "the v025 migration" do
    test "adds only the columns a house does not have yet", %{main: main} do
      {:ok, handle} = Storage.open(main, name: nil)
      on_exit(fn -> Storage.close(handle) end)
      v025 = [{25, Whiska.Migrations.V025PickupRetries}]
      Ecto.Migrator.run(Whiska.Repo, v025, :down, all: true, log: false)

      for column <- ~w(pickups stall_kind retry_at stalled_at stall_hooted_at) do
        Whiska.Repo.query!("ALTER TABLE mice ADD COLUMN #{column} TEXT")
      end

      Ecto.Migrator.run(Whiska.Repo, v025, :up, all: true, log: false)

      %{rows: rows} = Whiska.Repo.query!("SELECT name FROM pragma_table_info('mice')")
      columns = List.flatten(rows)

      for column <- ~w(pickups stall_kind retry_at stall_failed stalled_at stall_hooted_at),
          do: assert(column in columns)
    end
  end

  describe "open/1" do
    test "creates the database and migrates it", %{main: main} do
      {:ok, handle} = Storage.open(main, name: nil)
      on_exit(fn -> Storage.close(handle) end)

      assert File.exists?(Storage.database_path(main))
      # Both tables exist from day one, at their real schema (ADR-0028), so
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

    test "defaults mode to build (ADR-0069)" do
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
      # ADR-0011: the hook denies rather than asks, so there is no rule
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

    test "records the branch the worktree was cut from, and a later shape keeps it" do
      assert {:ok, _} = Storage.shape("m1", "build", nil, nil, "staging")
      assert Storage.mouse("m1").base == "staging"

      assert {:ok, _} = Storage.shape("m1", "sniff", nil, nil)
      assert Storage.mouse("m1").base == "staging"

      assert {:ok, _} = Storage.shape("m1", "sniff", nil, nil, "elsewhere")
      assert Storage.mouse("m1").base == "staging"
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

  describe "shapes and the mice recorded before them (ADR-0069)" do
    setup %{main: main} do
      {:ok, handle} = Storage.open(main)
      on_exit(fn -> Storage.close(handle) end)
      {:ok, _} = Storage.record_mouse(%{mouse_id: "m1", path: "/w/a", branch: "a"})
      :ok
    end

    test "a mouse recorded before shapes existed reads as shaped" do
      # Migration 7 grandfathers every mouse already in the house: it was
      # running as build when shapes arrived.
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

  describe "a shape and what it was shaped as (ADR-0074)" do
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

    test "shaping it again replaces what it was shaped as" do
      {:ok, _} = Storage.shape("m1", "sniff", "m-heavy", "xhigh")
      {:ok, _} = Storage.shape("m1", "build", "m-light", "low")
      assert Storage.mouse("m1").shaped_as == "build"
    end
  end

  describe "mode/1 (ADR-0069)" do
    setup %{main: main} do
      {:ok, handle} = Storage.open(main, name: nil)
      on_exit(fn -> Storage.close(handle) end)
      {:ok, _} = Storage.record_mouse(%{mouse_id: "m1", path: "/w/a", branch: "a"})
      :ok
    end

    test "a mouse nobody shaped reads as unshaped, whatever is stored (ADR-0069)" do
      assert Storage.mode("m1") == {:ok, "unshaped"}
    end

    test "routine bookkeeping never clobbers the mode" do
      # The hook calls record_mouse on every invocation to refresh the labels;
      # that must not quietly reset a sniff mouse to build.
      {:ok, _} = Storage.shape("m1", "sniff", nil, nil)
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
