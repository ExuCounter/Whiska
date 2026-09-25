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
      inner_main = make(root, "outer/worktrees/a")
      inner_worktree = make(root, "outer/worktrees/a/worktrees/b")

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
