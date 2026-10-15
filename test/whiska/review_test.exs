defmodule Whiska.ReviewTest do
  use ExUnit.Case, async: true

  alias Whiska.Review

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-review-#{Whiska.Test.Unique.id()}")
    main = Path.join(root, "repo")
    File.mkdir_p!(Path.join(main, ".git/info"))
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root, main: main}
  end

  describe "write/3" do
    test "writes the diff as it is, one patch file per branch beside the kept specs, ignored",
         %{main: main} do
      assert {:ok, path} = Review.write(main, "feat/x", "diff --git a/x b/x\n+a\n")

      assert path == Review.file(main, "feat/x")
      assert Path.basename(path) =~ ~r/^feat-x-[0-9a-f]{32}\.diff$/
      assert File.read!(path) == "diff --git a/x b/x\n+a\n"
      assert File.read!(Path.join(main, ".git/info/exclude")) =~ "/.whiska/"
    end

    test "two branches whose names read alike keep a file each", %{main: main} do
      paths =
        for branch <- ["feat/x", "feat-x", "fix/é", "fix/ü"] do
          {:ok, path} = Review.write(main, branch, "+#{branch}\n")
          path
        end

      assert length(Enum.uniq(paths)) == 4
      assert Enum.all?(paths, &(Path.dirname(&1) == Path.join(main, ".whiska/reviews")))
    end

    test "a branch name too long for a file name still gets its file", %{main: main} do
      branch = "feat/" <> String.duplicate("a", 300)

      assert {:ok, path} = Review.write(main, branch, "+a\n")
      assert byte_size(Path.basename(path)) <= 255
      refute Review.file(main, branch) == Review.file(main, branch <> "b")
    end

    test "never writes through a link in its folder", %{root: root, main: main} do
      elsewhere = Path.join(root, "elsewhere")
      File.mkdir_p!(elsewhere)
      File.mkdir_p!(Path.join(main, ".whiska"))
      File.ln_s!(elsewhere, Path.join(main, ".whiska/reviews"))

      assert {:error, _} = Review.write(main, "feat/x", "+a\n")
      assert File.ls!(elsewhere) == []
    end

    test "replaces a link at the file itself rather than writing through it",
         %{root: root, main: main} do
      target = Path.join(root, "target.diff")
      File.write!(target, "untouched")
      File.mkdir_p!(Path.join(main, ".whiska/reviews"))
      File.ln_s!(target, Review.file(main, "feat/x"))

      assert {:ok, path} = Review.write(main, "feat/x", "+a\n")
      assert File.read!(target) == "untouched"
      assert {:ok, %{type: :regular}} = File.lstat(path)
    end
  end

  test "a path that would break the Markdown link reaches it encoded" do
    assert Review.file_link("/w/feat/a(b) c/.whiska-spec.md") ==
             "file:///w/feat/a%28b%29%20c/.whiska-spec.md"
  end

  describe "remove/2" do
    test "removes only that branch's file", %{main: main} do
      {:ok, gone} = Review.write(main, "feat/x", "+a\n")
      {:ok, kept} = Review.write(main, "feat-x", "+b\n")

      assert :ok = Review.remove(main, "feat/x")
      refute File.exists?(gone)
      assert File.exists?(kept)
    end

    test "a file never written is already removed", %{main: main} do
      assert :ok = Review.remove(main, "feat/never")
    end

    test "never removes through a link in its folder", %{root: root, main: main} do
      elsewhere = Path.join(root, "elsewhere")
      File.mkdir_p!(elsewhere)
      File.mkdir_p!(Path.join(main, ".whiska"))
      File.ln_s!(elsewhere, Path.join(main, ".whiska/reviews"))
      victim = Path.join(elsewhere, Path.basename(Review.file(main, "feat/x")))
      File.write!(victim, "theirs")

      assert {:error, _} = Review.remove(main, "feat/x")
      assert File.read!(victim) == "theirs"
    end

    test "removes a link at the file, never what it points to", %{root: root, main: main} do
      target = Path.join(root, "target.diff")
      File.write!(target, "untouched")
      File.mkdir_p!(Path.join(main, ".whiska/reviews"))
      File.ln_s!(target, Review.file(main, "feat/x"))

      assert :ok = Review.remove(main, "feat/x")
      assert File.read!(target) == "untouched"
      assert {:error, :enoent} = File.lstat(Review.file(main, "feat/x"))
    end
  end
end
