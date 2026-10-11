defmodule Whiska.WriteupTest do
  use ExUnit.Case, async: true

  alias Whiska.Writeup

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-writeup-#{System.unique_integer([:positive])}")
    worktree = Path.join(root, "worktrees/research-x")
    File.mkdir_p!(Path.join(worktree, "lib"))
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root, worktree: worktree}
  end

  describe "target?/2" do
    test "names the write-up at the worktree root, by its absolute path", %{worktree: wt} do
      assert Writeup.target?(Path.join(wt, ".whiska-writeup.md"), wt)
    end

    test "a relative path is no write-up: where it lands depends on the session's folder",
         %{worktree: wt} do
      refute Writeup.target?(".whiska-writeup.md", wt)
    end

    test "a path that climbs through a folder is no write-up", %{worktree: wt} do
      refute Writeup.target?(Path.join(wt, "lib/../.whiska-writeup.md"), wt)
    end
  end

  describe "find/2" do
    defp kept(root, text) do
      path = Writeup.kept(root, 7)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, text)
    end

    test "titles the link with no character that could break or reorder it", %{root: root} do
      kept(root, "# Why \\it [hangs]\u202E <b>\e[31m\\\n")
      assert {_path, "Why it hangs? b?31m"} = Writeup.find(root, 7)
    end

    test "a lone # takes no title from the paragraph under it", %{root: root} do
      kept(root, "#\nFound it.\n")
      assert {_path, "write-up"} = Writeup.find(root, 7)
    end
  end
end
