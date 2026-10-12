defmodule Whiska.ReviewTest do
  use ExUnit.Case, async: true

  alias Whiska.Review

  test "the diff sits in a fence no line of it can close" do
    text = Review.render("main", "feat-x", 1, "+````\n+```\n")

    assert text =~ ~r/^`````diff\n\+````\n\+```\n`````$/m
  end

  test "a diff with no backticks gets the plain three" do
    assert Review.render("main", "feat-x", 2, "+a\n") =~ ~r/^```diff\n\+a\n```$/m
  end

  describe "write/6" do
    setup do
      root = Path.join(System.tmp_dir!(), "whiska-review-#{System.unique_integer([:positive])}")
      main = Path.join(root, "repo")
      File.mkdir_p!(Path.join(main, ".git/info"))
      on_exit(fn -> File.rm_rf!(root) end)
      {:ok, root: root, main: main}
    end

    test "writes one file per branch beside the kept specs, ignored", %{main: main} do
      assert {:ok, path} = Review.write(main, "main", "feat/x", 1, "+a\n")

      assert path == Review.file(main, "feat/x")
      assert Path.basename(path) =~ ~r/^feat-x-[0-9a-f]{8}\.md$/
      assert File.read!(path) =~ "+a"
      assert File.read!(Path.join(main, ".git/info/exclude")) =~ "/.whiska/"
    end

    test "two branches whose names read alike keep a file each", %{main: main} do
      paths =
        for branch <- ["feat/x", "feat-x", "fix/é", "fix/ü"] do
          {:ok, path} = Review.write(main, "main", branch, 1, "+#{branch}\n")
          path
        end

      assert length(Enum.uniq(paths)) == 4
      assert Enum.all?(paths, &(Path.dirname(&1) == Path.join(main, ".whiska/reviews")))
    end

    test "never writes through a link in its folder", %{root: root, main: main} do
      elsewhere = Path.join(root, "elsewhere")
      File.mkdir_p!(elsewhere)
      File.mkdir_p!(Path.join(main, ".whiska"))
      File.ln_s!(elsewhere, Path.join(main, ".whiska/reviews"))

      assert {:error, _} = Review.write(main, "main", "feat/x", 1, "+a\n")
      assert File.ls!(elsewhere) == []
    end

    test "replaces a link at the file itself rather than writing through it",
         %{root: root, main: main} do
      target = Path.join(root, "target.md")
      File.write!(target, "untouched")
      File.mkdir_p!(Path.join(main, ".whiska/reviews"))
      File.ln_s!(target, Review.file(main, "feat/x"))

      assert {:ok, path} = Review.write(main, "main", "feat/x", 1, "+a\n")
      assert File.read!(target) == "untouched"
      assert {:ok, %{type: :regular}} = File.lstat(path)
    end
  end

  test "it says what it compares" do
    text = Review.render("main", "feat-x", 2, "+a\n")

    assert text =~ "# feat-x against main"
    assert text =~ "2 commits, from `git diff main...feat-x`"
  end
end
