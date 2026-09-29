defmodule Whiska.LayoutTest do
  use ExUnit.Case, async: true

  alias Whiska.Layout

  # Worktrees are laid out under <main-checkout>/worktrees/<branch>/ by
  # spawn-worktree, and ADR-0030 says to lean on exactly that layout rather than
  # on git internals. So the whole derivation is: walk up until you find an
  # ancestor whose parent directory is named "worktrees".

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-layout-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  defp make(root, rel) do
    path = Path.join(root, rel)
    File.mkdir_p!(path)
    path
  end

  # A git worktree checkout carries a `.git` *file* pointing into the main
  # checkout's `.git/worktrees/`; a plain clone carries a `.git` directory, and a
  # submodule a `.git` file pointing into `.git/modules/`.
  defp checkout(root, rel) do
    path = make(root, rel)
    File.write!(Path.join(path, ".git"), "gitdir: /somewhere/.git/worktrees/x\n")
    path
  end

  defp submodule(root, rel) do
    path = make(root, rel)
    File.write!(Path.join(path, ".git"), "gitdir: ../../.git/modules/dep\n")
    path
  end

  describe "resolve/1 inside a worktree" do
    test "derives the worktree root and the main checkout from the layout", %{root: root} do
      main = make(root, "myrepo")
      worktree = make(root, "myrepo/worktrees/feat-thing")

      assert {:ok, layout} = Layout.resolve(worktree)
      assert layout.worktree_root == worktree
      assert layout.main_checkout == main
    end

    test "works from a nested directory deep inside the worktree", %{root: root} do
      main = make(root, "myrepo")
      worktree = make(root, "myrepo/worktrees/feat-thing")
      nested = make(root, "myrepo/worktrees/feat-thing/lib/whiska/deep")

      assert {:ok, layout} = Layout.resolve(nested)
      assert layout.worktree_root == worktree
      assert layout.main_checkout == main
    end

    test "picks the innermost worktrees ancestor when the layout nests", %{root: root} do
      inner_main = checkout(root, "outer/worktrees/a")
      inner_worktree = checkout(root, "outer/worktrees/a/worktrees/b")

      assert {:ok, layout} = Layout.resolve(inner_worktree)
      assert layout.worktree_root == inner_worktree
      assert layout.main_checkout == inner_main
    end

    test "carries the worktree directory name as the branch label", %{root: root} do
      make(root, "myrepo")
      worktree = make(root, "myrepo/worktrees/feat-thing")

      assert {:ok, layout} = Layout.resolve(worktree)
      assert layout.branch_label == "feat-thing"
    end

    test "keeps the flat case identical when the worktree is a real checkout", %{root: root} do
      main = make(root, "myrepo")
      worktree = checkout(root, "myrepo/worktrees/feat-thing")

      assert {:ok, layout} = Layout.resolve(worktree)
      assert layout.worktree_root == worktree
      assert layout.main_checkout == main
      assert layout.branch_label == "feat-thing"
    end
  end

  describe "resolve/1 when the branch name has a slash in it" do
    # git nests `feat/csv-data-page` on disk, so the worktree sits at
    # worktrees/feat/csv-data-page and worktrees/feat is a plain directory.

    test "takes the deepest checkout as the worktree root", %{root: root} do
      main = make(root, "myrepo")
      worktree = checkout(root, "myrepo/worktrees/feat/csv-data-page")

      assert {:ok, layout} = Layout.resolve(worktree)
      assert layout.worktree_root == worktree
      assert layout.main_checkout == main
    end

    test "spells the branch label with the slash back in", %{root: root} do
      make(root, "myrepo")
      checkout(root, "myrepo/worktrees/feat/csv-data-page")

      assert {:ok, layout} = Layout.resolve(root <> "/myrepo/worktrees/feat/csv-data-page")
      assert layout.branch_label == "feat/csv-data-page"
    end

    test "resolves the same from a directory deep inside it", %{root: root} do
      main = make(root, "myrepo")
      worktree = checkout(root, "myrepo/worktrees/feat/csv-data-page")
      nested = make(root, "myrepo/worktrees/feat/csv-data-page/app/routes")

      assert {:ok, layout} = Layout.resolve(nested)
      assert layout.worktree_root == worktree
      assert layout.main_checkout == main
      assert layout.branch_label == "feat/csv-data-page"
    end

    test "handles a branch name with more than one slash", %{root: root} do
      checkout(root, "myrepo/worktrees/team/feat/deep-thing")

      assert {:ok, layout} = Layout.resolve(root <> "/myrepo/worktrees/team/feat/deep-thing")
      assert layout.branch_label == "team/feat/deep-thing"
    end

    test "does not descend past the container into a sibling branch", %{root: root} do
      checkout(root, "myrepo/worktrees/feat/one")
      other = checkout(root, "myrepo/worktrees/feat/two")

      assert {:ok, layout} = Layout.resolve(other)
      assert layout.worktree_root == other
      assert layout.branch_label == "feat/two"
    end

    test "falls back to the directory under worktrees when nothing is a checkout", %{root: root} do
      worktree = make(root, "myrepo/worktrees/feat-thing")
      make(root, "myrepo/worktrees/feat-thing/lib")

      assert {:ok, layout} = Layout.resolve(worktree <> "/lib")
      assert layout.worktree_root == worktree
      assert layout.branch_label == "feat-thing"
    end

    test "a submodule inside a worktree is not the worktree root", %{root: root} do
      main = make(root, "myrepo")
      worktree = checkout(root, "myrepo/worktrees/feat/csv-data-page")
      vendored = submodule(root, "myrepo/worktrees/feat/csv-data-page/vendor/dep")

      assert {:ok, layout} = Layout.resolve(vendored)
      assert layout.worktree_root == worktree
      assert layout.main_checkout == main
      assert layout.branch_label == "feat/csv-data-page"
    end

    test "a gitdir written relative still counts when it points at a worktree", %{root: root} do
      path = make(root, "myrepo/worktrees/feat/relative")
      File.write!(Path.join(path, ".git"), "gitdir: ../../../.git/worktrees/relative\n")

      assert {:ok, layout} = Layout.resolve(path)
      assert layout.branch_label == "feat/relative"
    end

    test "never takes a checkout above the container as the root", %{root: root} do
      outer = checkout(root, "myrepo/worktrees/outer")
      inner = make(root, "myrepo/worktrees/outer/worktrees/inner/lib")

      assert {:ok, layout} = Layout.resolve(inner)
      assert layout.worktree_root == Path.dirname(inner)
      assert layout.main_checkout == outer
      assert layout.branch_label == "inner"
    end

    test "a .git directory is a clone, not a worktree checkout", %{root: root} do
      plain = make(root, "myrepo/worktrees/vendored/clone")
      File.mkdir_p!(Path.join(plain, ".git"))

      assert {:ok, layout} = Layout.resolve(plain)
      assert layout.branch_label == "vendored"
    end
  end

  describe "resolve/1 outside a worktree" do
    test "returns :not_in_worktree from the main checkout itself", %{root: root} do
      main = make(root, "myrepo")
      make(root, "myrepo/worktrees/feat-thing")

      assert {:error, :not_in_worktree} = Layout.resolve(main)
    end

    test "returns :not_in_worktree for a path with no worktrees ancestor", %{root: root} do
      elsewhere = make(root, "somewhere/else/entirely")

      assert {:error, :not_in_worktree} = Layout.resolve(elsewhere)
    end

    test "does not mistake the worktrees container itself for a worktree", %{root: root} do
      make(root, "myrepo")
      container = make(root, "myrepo/worktrees")

      assert {:error, :not_in_worktree} = Layout.resolve(container)
    end
  end

  describe "inside?/2" do
    test "is true for the directory itself and anything beneath it" do
      assert Layout.inside?("/a/b", "/a/b")
      assert Layout.inside?("/a/b/c.txt", "/a/b")
      assert Layout.inside?("/a/b/c/d.txt", "/a/b")
    end

    test "is false for siblings and for prefix lookalikes" do
      refute Layout.inside?("/a/c", "/a/b")
      refute Layout.inside?("/a/bb/c.txt", "/a/b")
      refute Layout.inside?("/a", "/a/b")
    end
  end
end
