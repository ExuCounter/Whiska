defmodule Whiska.SpecArchiveTest do
  use ExUnit.Case, async: true

  alias Whiska.Doorstep.Entry
  alias Whiska.Schema.Question
  alias Whiska.SpecArchive

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-archive-#{System.unique_integer([:positive])}")
    main = Path.join(root, "repo")
    File.mkdir_p!(Path.join(main, ".git/info"))
    on_exit(fn -> File.rm_rf!(root) end)

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

    assert {:error, _} = SpecArchive.keep_research(main, entry, %Question{id: 7})
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

    assert :kept = SpecArchive.keep_research(main, entry, %Question{id: 7})
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
end
