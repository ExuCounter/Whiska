defmodule Whiska.AdrTest do
  @moduledoc """
  This repo's own `docs/adr/`: a record is written under a placeholder and claims its
  number when it lands (ADR-next-an-adr-claims-its-number-when-it-lands).

  Placeholders in these fixtures are built with `ph/1` rather than written out, so the
  repo-wide check at the bottom never mistakes this file's examples for real citations.
  """
  use ExUnit.Case, async: true

  alias Whiska.Adr
  alias Whiska.Test.GitRepo

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-adr-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  # A citation of a placeholder: "ADR-" "next-" and the slug.
  defp ph(slug), do: "ADR-" <> "next-" <> slug
  defp cite(n), do: "ADR-" <> n

  defp write(root, path, contents) do
    full = Path.join(root, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, contents)
  end

  defp adrs(root, names), do: Enum.each(names, &write(root, "docs/adr/#{&1}", "# #{&1}\n"))

  # Nothing landed since the branch was cut: main and the merge base hold what the tree does.
  defp level(root) do
    names = root |> Path.join("docs/adr") |> File.ls!()
    %{main: names, base: names}
  end

  describe "problems/2, numbers" do
    test "a tree with every number once and every citation resolving is clean", %{root: root} do
      adrs(root, ["0001-a.md", "0002-b.md"])
      write(root, "lib/x.ex", "# per #{cite("0002")}\n")
      write(root, "docs/adr/README.md", "- [0001](0001-a.md) — A\n")

      assert Adr.problems(root, level(root)) == []
    end

    test "two files with one number is a collision", %{root: root} do
      adrs(root, ["0001-a.md", "0002-b.md", "0002-c.md"])

      assert [problem] = Adr.problems(root, level(root))
      assert problem =~ "0002"
      assert problem =~ "0002-b.md"
      assert problem =~ "0002-c.md"
    end

    test "a number main added since this branch was cut collides with the branch's own",
         %{root: root} do
      adrs(root, ["0001-a.md", "0002-mine.md"])
      view = %{main: ["0001-a.md", "0002-theirs.md"], base: ["0001-a.md"]}

      assert [problem] = Adr.problems(root, view)
      assert problem =~ "0002-mine.md"
      assert problem =~ "0002-theirs.md"
    end

    test "a file this branch renamed is not a collision with its old name", %{root: root} do
      adrs(root, ["0001-new-name.md"])
      view = %{main: ["0001-old-name.md"], base: ["0001-old-name.md"]}

      assert Adr.problems(root, view) == []
    end

    test "a file main renamed since this branch was cut is not a collision", %{root: root} do
      adrs(root, ["0001-old-name.md"])
      view = %{main: ["0001-new-name.md"], base: ["0001-old-name.md"]}

      assert Adr.problems(root, view) == []
    end
  end

  describe "problems/2, citations" do
    test "a citation with the wrong number of digits is named", %{root: root} do
      adrs(root, ["0001-a.md"])
      write(root, "lib/x.ex", "# per #{cite("00011")}\n")

      assert [problem] = Adr.problems(root, level(root))
      assert problem =~ cite("00011")
    end

    test "a link with an anchor or a ./ prefix is still checked", %{root: root} do
      adrs(root, ["0001-a.md"])
      write(root, "docs/adr/README.md", "[x](./0002-gone.md) [y](0003-gone.md#why)\n")

      assert [_, _] = Adr.problems(root, level(root))
    end

    test "a numbered citation with no file behind it is named with where it is", %{root: root} do
      adrs(root, ["0001-a.md"])
      write(root, "lib/x.ex", "# per #{cite("0009")}\n")

      assert [problem] = Adr.problems(root, level(root))
      assert problem =~ cite("0009")
      assert problem =~ "lib/x.ex"
    end

    test "a placeholder citation with no file behind it is named", %{root: root} do
      adrs(root, ["0001-a.md"])
      write(root, "test/x_test.exs", "# per #{ph("ghost")}\n")

      assert [problem] = Adr.problems(root, level(root))
      assert problem =~ ph("ghost")
      assert problem =~ "test/x_test.exs"
    end

    test "a symlink out of the repo is not followed", %{root: root} do
      adrs(root, ["0001-a.md"])
      outside = root <> "-outside"
      write(outside, "x.ex", "# per #{cite("0009")}\n")
      on_exit(fn -> File.rm_rf!(outside) end)
      File.mkdir_p!(Path.join(root, "test"))
      File.ln_s!(outside, Path.join(root, "test/out"))

      assert Adr.problems(root, level(root)) == []
    end

    test "a README link to a file that is not there is named", %{root: root} do
      adrs(root, ["0001-a.md"])
      write(root, "docs/adr/README.md", "- [0002](0002-gone.md) — Gone\n")

      assert [problem] = Adr.problems(root, level(root))
      assert problem =~ "0002-gone.md"
    end
  end

  describe "problems/2, placeholders" do
    test "a placeholder main does not have yet is a branch in flight, and fine", %{root: root} do
      adrs(root, ["0001-a.md", "next-thing.md"])
      write(root, "lib/x.ex", "# per #{ph("thing")}\n")
      view = %{main: ["0001-a.md"], base: ["0001-a.md"]}

      assert Adr.problems(root, view) == []
    end

    test "a placeholder main already holds reached main unclaimed", %{root: root} do
      adrs(root, ["0001-a.md", "next-thing.md"])

      assert [problem] = Adr.problems(root, level(root))
      assert problem =~ "next-thing.md"
      assert problem =~ "mix adr.claim"
    end
  end

  describe "view/1 against real git" do
    test "the same placeholder passes on its branch and fails once landed on main",
         %{root: root} do
      repo = GitRepo.create(root)
      mkdir(repo.checkout, "docs/adr/0001-a.md")
      GitRepo.commit!(repo.checkout, "docs/adr/0001-a.md", "a")
      branch = GitRepo.worktree(repo, "adr-branch", commit: false, push: false)
      mkdir(branch, "docs/adr/next-thing.md")
      GitRepo.commit!(branch, "docs/adr/next-thing.md", "thing")

      assert Adr.problems(branch, Adr.view(branch)) == []

      GitRepo.land(repo, "adr-branch", push: false)

      assert [problem] = Adr.problems(repo.checkout, Adr.view(repo.checkout))
      assert problem =~ "next-thing.md"
    end

    test "a number main took after the branch was cut is seen from the branch", %{root: root} do
      repo = GitRepo.create(root)
      mkdir(repo.checkout, "docs/adr/0001-a.md")
      GitRepo.commit!(repo.checkout, "docs/adr/0001-a.md", "a")
      branch = GitRepo.worktree(repo, "adr-branch", commit: false, push: false)
      GitRepo.commit!(repo.checkout, "docs/adr/0002-theirs.md", "theirs")
      GitRepo.commit!(branch, "docs/adr/0002-mine.md", "mine")

      assert [problem] = Adr.problems(branch, Adr.view(branch))
      assert problem =~ "0002-theirs.md"
    end
  end

  describe "claim/2" do
    test "the next number after both the tree and main replaces the placeholder everywhere",
         %{root: root} do
      adrs(root, ["0001-a.md", "next-thing.md"])
      write(root, "docs/adr/README.md", "- [next-thing](next-thing.md) — Thing\n")
      write(root, "lib/x.ex", "# per #{ph("thing")}, see next-thing.md\n")
      view = %{main: ["0001-a.md", "0002-landed.md"], base: ["0001-a.md"]}

      assert Adr.claim(root, view) == [{"next-thing.md", "0003-thing.md"}]

      assert File.ls!(Path.join(root, "docs/adr")) |> Enum.sort() ==
               ["0001-a.md", "0003-thing.md", "README.md"]

      assert File.read!(Path.join(root, "docs/adr/README.md")) ==
               "- [0003](0003-thing.md) — Thing\n"

      assert File.read!(Path.join(root, "lib/x.ex")) ==
               "# per #{cite("0003")}, see 0003-thing.md\n"
    end

    test "two placeholders take consecutive numbers, and a longer slug is not cut short",
         %{root: root} do
      adrs(root, ["0001-a.md", "next-thing.md", "next-thing-more.md"])
      write(root, "lib/x.ex", "#{ph("thing")} #{ph("thing-more")}\n")

      assert Adr.claim(root, level(root) |> Map.put(:main, ["0001-a.md"])) == [
               {"next-thing-more.md", "0002-thing-more.md"},
               {"next-thing.md", "0003-thing.md"}
             ]

      assert File.read!(Path.join(root, "lib/x.ex")) == "#{cite("0003")} #{cite("0002")}\n"
    end

    test "with nothing to claim it changes nothing", %{root: root} do
      adrs(root, ["0001-a.md"])
      assert Adr.claim(root, level(root)) == []
    end
  end

  test "this repo's own records have no collision, no dangling citation, nothing unclaimed" do
    root = File.cwd!()
    assert Adr.problems(root, Adr.view(root)) == []
  end

  defp mkdir(dir, file), do: File.mkdir_p!(Path.dirname(Path.join(dir, file)))
end
