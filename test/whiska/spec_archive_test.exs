defmodule Whiska.SpecArchiveTest do
  use ExUnit.Case, async: true

  alias Whiska.Doorstep.Entry
  alias Whiska.SpecArchive
  alias Whiska.Storage

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-archive-#{Whiska.Test.Unique.id()}")
    main = Path.join(root, "repo")
    File.mkdir_p!(Path.join(main, ".git/info"))
    on_exit(fn -> File.rm_rf!(root) end)

    # Unnamed, so each test has a house of its own.
    {:ok, handle} = Storage.open(main, name: nil)
    on_exit(fn -> if Process.alive?(handle), do: Storage.close(handle) end)
    {:ok, _} = Storage.record_mouse(%{mouse_id: "m1", path: "/w/a", branch: "feat-a"})

    entry = %Entry{
      mouse_id: "m1",
      branch: "feat-a",
      worktree_root: "/w/a",
      stamped_at: ~U[2026-10-06 09:00:00Z],
      text: "Found it.",
      research: "# Found\n"
    }

    {:ok, root: root, main: main, entry: entry}
  end

  test "never writes a research document through a link in its folder",
       %{root: root, main: main, entry: entry} do
    elsewhere = Path.join(root, "elsewhere")
    File.mkdir_p!(elsewhere)
    File.mkdir_p!(Path.join(main, ".whiska"))
    File.ln_s!(elsewhere, Path.join(main, ".whiska/specs"))

    assert {:error, _} = SpecArchive.keep_research(main, entry)
    assert File.ls!(elsewhere) == []
  end

  test "never writes a research document through a link at its name",
       %{root: root, main: main, entry: entry} do
    for {name, target} <- [{"2026-10-06-feat-a", "kept.md"}, {"2026-10-06-feat-a-2", "gone.md"}] do
      File.mkdir_p!(SpecArchive.dir(main))

      File.ln_s!(
        Path.join(root, target),
        Path.join(SpecArchive.dir(main), name <> ".research.md")
      )
    end

    File.write!(Path.join(root, "kept.md"), "untouched")

    assert :kept = SpecArchive.keep_research(main, entry)
    assert File.read!(Path.join(root, "kept.md")) == "untouched"
    refute File.exists?(Path.join(root, "gone.md"))

    assert [_kept] =
             main
             |> SpecArchive.dir()
             |> File.ls!()
             |> Enum.filter(
               &match?({:ok, %{type: :regular}}, File.lstat(Path.join(SpecArchive.dir(main), &1)))
             )
  end

  describe "a kept document" do
    test "is the text as sent, with no header", %{main: main, entry: entry} do
      report = "# Done\n\n## Summary\nx\n"
      text = %{entry | text: report}

      assert :kept = SpecArchive.keep_document(main, text, "build")
      assert [file] = Path.wildcard(Path.join(SpecArchive.dir(main), "*.report.md"))
      assert File.read!(file) == report
      assert SpecArchive.report(main, Storage.mouse("m1")) == file
    end

    test "a revision overwrites its file, and the same text writes nothing",
         %{main: main, entry: entry} do
      assert :kept = SpecArchive.keep(main, %{entry | spec: "# One\n"})
      assert :unchanged = SpecArchive.keep(main, %{entry | spec: "# One\n"})
      assert :kept = SpecArchive.keep(main, %{entry | spec: "# Two\n"})

      assert [file] = Path.wildcard(Path.join(SpecArchive.dir(main), "*.md"))
      assert File.read!(file) == "# Two\n"
    end

    test "every kind sits beside the first one kept for its mouse", %{main: main, entry: entry} do
      :kept = SpecArchive.keep_plan(main, %{entry | plan: "# Plan\n"})
      :kept = SpecArchive.keep(main, %{entry | spec: "# Spec\n"})
      :kept = SpecArchive.keep_research(main, entry)

      assert main |> SpecArchive.dir() |> File.ls!() |> Enum.sort() == [
               "2026-10-06-feat-a.md",
               "2026-10-06-feat-a.plan.md",
               "2026-10-06-feat-a.research.md"
             ]

      assert Storage.mouse("m1").kept_as == "2026-10-06-feat-a"
    end

    test "two mice on one branch each find their own", %{main: main, entry: entry} do
      {:ok, _} = Storage.record_mouse(%{mouse_id: "m2", path: "/w/b", branch: "feat-a"})
      :kept = SpecArchive.keep_research(main, entry)
      :kept = SpecArchive.keep_research(main, %{entry | mouse_id: "m2", research: "# Two\n"})

      assert SpecArchive.research(main, Storage.mouse("m1")) |> File.read!() == "# Found\n"
      assert SpecArchive.research(main, Storage.mouse("m2")) |> File.read!() == "# Two\n"
    end

    test "a plan kept with no spec never pairs with a later mouse's spec",
         %{main: main, entry: entry} do
      {:ok, _} = Storage.record_mouse(%{mouse_id: "m2", path: "/w/b", branch: "feat-a"})
      :kept = SpecArchive.keep_plan(main, %{entry | plan: "# Bug plan\n"})
      :kept = SpecArchive.keep(main, %{entry | mouse_id: "m2", spec: "# Spec\n"})
      :kept = SpecArchive.keep_plan(main, %{entry | mouse_id: "m2", plan: "# Feature plan\n"})

      assert main |> SpecArchive.dir() |> File.ls!() |> Enum.sort() == [
               "2026-10-06-feat-a-2.md",
               "2026-10-06-feat-a-2.plan.md",
               "2026-10-06-feat-a.plan.md"
             ]
    end

    test "never takes a name another mouse holds, even with its files gone",
         %{main: main, entry: entry} do
      {:ok, _} = Storage.record_mouse(%{mouse_id: "m2", path: "/w/b", branch: "feat-a"})
      :ok = Storage.set_kept_as("m1", "2026-10-06-feat-a")
      :kept = SpecArchive.keep_research(main, %{entry | mouse_id: "m2"})

      assert Storage.mouse("m2").kept_as == "2026-10-06-feat-a-2"
    end

    test "for a mouse with no record is still written, under a name of its own",
         %{main: main, entry: entry} do
      :kept = SpecArchive.keep_research(main, entry)
      assert :kept = SpecArchive.keep_research(main, %{entry | mouse_id: "nobody"})

      assert main |> SpecArchive.dir() |> File.ls!() |> Enum.sort() == [
               "2026-10-06-feat-a-2.research.md",
               "2026-10-06-feat-a.research.md"
             ]
    end
  end

  describe "unhead/1" do
    test "strips each header and names the file on its mouse's record", %{main: main} do
      dir = SpecArchive.dir(main)
      File.mkdir_p!(dir)

      header = fn mouse ->
        "---\nrepo: repo\nbranch: feat-a\nmouse: #{mouse}\nquestion: 7\n" <>
          "written: 2026-10-06 09:00 UTC\nstatus: waiting\n---\n\n"
      end

      File.write!(Path.join(dir, "2026-10-06-feat-a.md"), header.("m1") <> "# Spec\n")
      File.write!(Path.join(dir, "2026-10-06-feat-a.report.md"), header.("m1") <> "# Report\n")
      File.write!(Path.join(dir, "2026-10-05-feat-x.md"), header.("gone") <> "# Old\n")
      File.write!(Path.join(dir, "2026-10-04-plain.md"), "---\nnot: ours\n")

      File.write!(
        Path.join(dir, "2026-10-03-other.md"),
        "---\ntitle: x\nmouse: who owns it\n---\n\n# Spec\n"
      )

      File.write!(
        Path.join(dir, "2026-10-02-fix.report.md"),
        "---\nbranch: fix.report\nmouse: m2\nstatus: waiting\n---\n\n# Fix\n"
      )

      {:ok, _} = Storage.record_mouse(%{mouse_id: "m2", path: "/w/b", branch: "fix.report"})

      assert :ok = SpecArchive.unhead(main)
      assert :ok = SpecArchive.unhead(main)

      assert File.read!(Path.join(dir, "2026-10-06-feat-a.md")) == "# Spec\n"
      assert File.read!(Path.join(dir, "2026-10-05-feat-x.md")) == "# Old\n"
      assert File.read!(Path.join(dir, "2026-10-04-plain.md")) == "---\nnot: ours\n"

      assert File.read!(Path.join(dir, "2026-10-03-other.md")) ==
               "---\ntitle: x\nmouse: who owns it\n---\n\n# Spec\n"

      assert Storage.mouse("m2").kept_as == "2026-10-02-fix.report"
      assert Storage.mouse("m1").kept_as == "2026-10-06-feat-a"
      assert SpecArchive.report(main, Storage.mouse("m1")) |> File.read!() == "# Report\n"
    end
  end
end
