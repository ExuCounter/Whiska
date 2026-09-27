defmodule Whiska.DoorstepTest do
  use ExUnit.Case, async: true

  alias Whiska.Doorstep
  alias Whiska.Doorstep.Entry

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-doorstep-#{System.unique_integer([:positive])}")
    main = Path.join(root, "myrepo")
    File.mkdir_p!(Path.join(main, ".git"))
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, main: main}
  end

  defp entry(overrides \\ %{}) do
    struct!(
      %Entry{
        mouse_id: "m1",
        branch: "feat-a",
        worktree_root: "/repo/worktrees/feat-a",
        stamped_at: ~U[2026-09-27 10:00:00Z],
        text: "All green.\n\n[worktree-status: done]"
      },
      overrides
    )
  end

  describe "path/1" do
    test "is in the house, beside the database, never in the worktree (ADR-0036)", %{main: main} do
      assert Doorstep.path(main) == Path.join(main, ".git/whiska/doorstep")
    end
  end

  describe "leave/2" do
    test "writes one file per entry and returns its path", %{main: main} do
      assert {:ok, file} = Doorstep.leave(main, entry())
      assert File.exists?(file)
      assert Path.dirname(file) == Doorstep.path(main)
      assert Path.extname(file) == ".json"
    end

    test "creates the doorstep on first use — the hook never checks", %{main: main} do
      refute File.exists?(Doorstep.path(main))
      assert {:ok, _} = Doorstep.leave(main, entry())
    end

    test "leaves no temporary file behind", %{main: main} do
      {:ok, _} = Doorstep.leave(main, entry())
      assert [file] = File.ls!(Doorstep.path(main))
      assert String.ends_with?(file, ".json")
    end

    test "two entries from the same mouse in the same second stay apart", %{main: main} do
      {:ok, a} = Doorstep.leave(main, entry())
      {:ok, b} = Doorstep.leave(main, entry())
      assert a != b
      assert length(Doorstep.waiting(main)) == 2
    end
  end

  describe "waiting/1" do
    test "is empty when there is no doorstep yet", %{main: main} do
      assert Doorstep.waiting(main) == []
    end

    test "reads entries back, oldest first", %{main: main} do
      {:ok, _} =
        Doorstep.leave(main, entry(%{text: "first", stamped_at: ~U[2026-09-27 10:00:00Z]}))

      {:ok, _} =
        Doorstep.leave(main, entry(%{text: "second", stamped_at: ~U[2026-09-27 10:00:05Z]}))

      assert [{_, %Entry{text: "first"} = first}, {_, %Entry{text: "second"}}] =
               Doorstep.waiting(main)

      assert first.mouse_id == "m1"
      assert first.branch == "feat-a"
      assert first.worktree_root == "/repo/worktrees/feat-a"
      assert first.stamped_at == ~U[2026-09-27 10:00:00Z]
    end

    test "skips a file it cannot parse, and keeps it in place to be looked at", %{main: main} do
      File.mkdir_p!(Doorstep.path(main))
      bad = Path.join(Doorstep.path(main), "0-broken.json")
      File.write!(bad, "{not json")
      {:ok, _} = Doorstep.leave(main, entry())

      assert [{_, %Entry{}}] = Doorstep.waiting(main)
      assert File.exists?(bad)
    end

    test "ignores a half-written temporary file", %{main: main} do
      File.mkdir_p!(Doorstep.path(main))
      File.write!(Path.join(Doorstep.path(main), "0-m1-x.json.tmp"), "{")

      assert Doorstep.waiting(main) == []
    end
  end

  describe "mark_collected/1 (collection reads and marks; it never deletes)" do
    test "renames the entry in place, so it stops waiting but stays on disk", %{main: main} do
      {:ok, file} = Doorstep.leave(main, entry())
      assert {:ok, kept} = Doorstep.mark_collected(file)

      assert Doorstep.waiting(main) == []
      assert File.exists?(kept)
      refute File.exists?(file)
      assert Path.dirname(kept) == Doorstep.path(main)
    end

    test "reports an entry that is already gone rather than raising", %{main: main} do
      assert {:error, :enoent} =
               Doorstep.mark_collected(Path.join(Doorstep.path(main), "nope.json"))
    end
  end

  describe "count_waiting/1 — what the statusline reads when the owl is down (ADR-0027)" do
    test "counts uncollected entries only", %{main: main} do
      {:ok, a} = Doorstep.leave(main, entry())
      {:ok, _} = Doorstep.leave(main, entry())
      {:ok, _} = Doorstep.mark_collected(a)

      assert Doorstep.count_waiting(main) == 1
    end
  end
end
