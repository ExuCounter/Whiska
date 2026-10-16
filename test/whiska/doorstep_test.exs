defmodule Whiska.DoorstepTest do
  use ExUnit.Case, async: true

  alias Whiska.Doorstep
  alias Whiska.Doorstep.Entry

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-doorstep-#{Whiska.Test.Unique.id()}")
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

  describe "hold/2 — a marked stop whose subagents are still out" do
    test "is on the doorstep but not waiting, until it is released", %{main: main} do
      assert {:ok, file} = Doorstep.hold(main, entry())

      assert Path.extname(file) == ".held"
      assert Doorstep.waiting(main) == []
      assert Doorstep.count_waiting(main) == 0
      assert [{^file, %Entry{mouse_id: "m1"}}] = Doorstep.held(main)

      assert {:ok, released} = Doorstep.release(file)
      assert Path.extname(released) == ".json"
      assert [{^released, %Entry{mouse_id: "m1"}}] = Doorstep.waiting(main)
      assert Doorstep.held(main) == []
    end

    test "keeps one held entry per mouse: a newer stop replaces the older", %{main: main} do
      {:ok, _} = Doorstep.hold(main, entry(%{text: "first"}))
      {:ok, _} = Doorstep.hold(main, entry(%{text: "second"}))
      {:ok, _} = Doorstep.hold(main, entry(%{mouse_id: "m2", text: "other"}))

      assert ["other", "second"] =
               main |> Doorstep.held() |> Enum.map(fn {_, e} -> e.text end) |> Enum.sort()
    end

    test "drop_held/2 removes one mouse's held entry and no other's", %{main: main} do
      {:ok, _} = Doorstep.hold(main, entry())
      {:ok, _} = Doorstep.hold(main, entry(%{mouse_id: "m2"}))

      assert Doorstep.drop_held(main, "m1") == 1
      assert [{_, %Entry{mouse_id: "m2"}}] = Doorstep.held(main)
    end

    test "hold/2 writes the new entry before it drops the old, so a failed write loses nothing",
         %{main: main} do
      {:ok, old} = Doorstep.hold(main, entry(%{text: "first"}))
      File.chmod!(Doorstep.path(main), 0o500)
      on_exit(fn -> File.chmod!(Doorstep.path(main), 0o700) end)

      assert {:error, _} = Doorstep.hold(main, entry(%{text: "second"}))
      assert [{^old, %Entry{text: "first"}}] = Doorstep.held(main)
    end

    test "a held entry still being written is not read", %{main: main} do
      File.mkdir_p!(Doorstep.path(main))
      File.write!(Path.join(Doorstep.path(main), "1-m1-x.held.tmp"), Entry.encode(entry()))

      assert Doorstep.held(main) == []
      assert Doorstep.waiting(main) == []
    end

    test "a held entry that will not parse is left where it is", %{main: main} do
      File.mkdir_p!(Doorstep.path(main))
      File.write!(Path.join(Doorstep.path(main), "1-m1-x.held"), "{nope")

      assert Doorstep.held(main) == []
      assert File.exists?(Path.join(Doorstep.path(main), "1-m1-x.held"))
    end
  end

  describe "an entry written before the spec travelled" do
    test "still reads, with no spec" do
      raw =
        ~s({"mouse_id":"m1","branch":"feat-a","worktree_root":"/w","stamped_at":"2026-10-06T09:00:00Z","text":"hi"})

      assert {:ok, %Entry{spec: nil, text: "hi"}} = Entry.decode(raw)
    end
  end

  describe "an entry written before the research document travelled" do
    test "still reads, with no research document" do
      raw =
        ~s({"mouse_id":"m1","branch":"feat-a","worktree_root":"/w","stamped_at":"2026-10-06T09:00:00Z","text":"hi","spec":null})

      assert {:ok, %Entry{research: nil, text: "hi"}} = Entry.decode(raw)
    end

    test "a research document survives the round trip" do
      {:ok, back} = entry(%{research: "# Found\n"}) |> Entry.encode() |> Entry.decode()
      assert back.research == "# Found\n"
    end
  end

  describe "an entry written before the build plan travelled" do
    test "still reads, with no build plan" do
      raw =
        ~s({"mouse_id":"m1","branch":"feat-a","worktree_root":"/w","stamped_at":"2026-10-06T09:00:00Z","text":"hi","spec":"# Spec"})

      assert {:ok, %Entry{plan: nil, spec: "# Spec"}} = Entry.decode(raw)
    end

    test "a build plan survives the round trip" do
      {:ok, back} = entry(%{plan: "# Build plan\n"}) |> Entry.encode() |> Entry.decode()
      assert back.plan == "# Build plan\n"
    end
  end

  describe "a reply" do
    test "survives the round trip, and an entry written before it is none" do
      {:ok, back} = entry(%{reply: true}) |> Entry.encode() |> Entry.decode()
      assert back.reply

      raw =
        ~s({"mouse_id":"m1","branch":"feat-a","worktree_root":"/w","stamped_at":"2026-10-06T09:00:00Z","text":"hi"})

      assert {:ok, %Entry{reply: false}} = Entry.decode(raw)
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

  describe "the model a turn ran on" do
    test "travels with the entry", %{main: main} do
      {:ok, _} = Doorstep.leave(main, entry(%{ran_on: "claude-a-5"}))
      assert [{_, %Entry{ran_on: "claude-a-5"}}] = Doorstep.waiting(main)
    end

    test "is nil on an entry written before it travelled", %{main: main} do
      File.mkdir_p!(Doorstep.path(main))

      File.write!(
        Path.join(Doorstep.path(main), "0-m1-old.json"),
        JSON.encode!(%{
          "mouse_id" => "m1",
          "branch" => "feat-a",
          "worktree_root" => "/repo/worktrees/feat-a",
          "stamped_at" => "2026-09-27T10:00:00Z",
          "text" => "x"
        })
      )

      assert [{_, %Entry{text: "x", ran_on: nil, transcript: nil}}] = Doorstep.waiting(main)
    end
  end

  describe "the transcript a turn wrote" do
    test "travels with the entry", %{main: main} do
      {:ok, _} = Doorstep.leave(main, entry(%{transcript: "/home/u/.claude/projects/p/s.jsonl"}))

      assert [{_, %Entry{transcript: "/home/u/.claude/projects/p/s.jsonl"}}] =
               Doorstep.waiting(main)
    end
  end

  describe "collected/1 (the row is the history; the entry is removed)" do
    test "deletes the entry, leaving nothing on the doorstep", %{main: main} do
      {:ok, file} = Doorstep.leave(main, entry())
      assert :ok = Doorstep.collected(file)

      assert Doorstep.waiting(main) == []
      refute File.exists?(file)
      assert File.ls!(Doorstep.path(main)) == []
    end

    test "an entry already gone counts as collected, not an error", %{main: main} do
      assert :ok =
               Doorstep.collected(Path.join(Doorstep.path(main), "nope.json"))
    end
  end

  describe "sweep_collected/1 (entries an older owl renamed)" do
    test "removes `.collected` files only", %{main: main} do
      {:ok, a} = Doorstep.leave(main, entry())
      {:ok, b} = Doorstep.leave(main, entry())
      File.rename!(a, a <> ".collected")
      File.write!(b <> ".tmp", "half")

      assert Doorstep.sweep_collected(main) == 1
      assert File.exists?(b)
      assert File.exists?(b <> ".tmp")
      refute File.exists?(a <> ".collected")
    end

    test "counts nothing when there is no doorstep", %{main: main} do
      assert Doorstep.sweep_collected(main) == 0
    end
  end

  describe "count_waiting/1 — what the statusline reads when the owl is down (ADR-0048)" do
    test "counts uncollected entries only", %{main: main} do
      {:ok, a} = Doorstep.leave(main, entry())
      {:ok, _} = Doorstep.leave(main, entry())
      :ok = Doorstep.collected(a)

      assert Doorstep.count_waiting(main) == 1
    end
  end
end
