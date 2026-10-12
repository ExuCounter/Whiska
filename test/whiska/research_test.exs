defmodule Whiska.ResearchTest do
  use ExUnit.Case, async: true

  alias Whiska.Research
  alias Whiska.Schema.Question

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-research-#{System.unique_integer([:positive])}")
    worktree = Path.join(root, "worktrees/research-x")
    File.mkdir_p!(Path.join(worktree, "lib"))
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root, worktree: worktree}
  end

  describe "target?/2" do
    test "names the research document at the worktree root, by its absolute path", %{worktree: wt} do
      assert Research.target?(Path.join(wt, ".whiska-research.md"), wt)
    end

    test "a relative path is no research document: where it lands depends on the session's folder",
         %{worktree: wt} do
      refute Research.target?(".whiska-research.md", wt)
    end

    test "a path that climbs through a folder is no research document", %{worktree: wt} do
      refute Research.target?(Path.join(wt, "lib/../.whiska-research.md"), wt)
    end
  end

  describe "find/3" do
    defp kept(root, text) do
      path = Path.join(root, ".whiska/research/7.md")
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, text)
    end

    defp find(root), do: Research.find(root, %Question{id: 7}, nil)

    test "titles the link with no character that could break or reorder it", %{root: root} do
      kept(root, "# Why \\it [hangs]\u202E <b>\e[31m\\\n")
      assert {_path, "Why it hangs? b?31m"} = find(root)
    end

    test "a lone # takes no title from the paragraph under it", %{root: root} do
      kept(root, "#\nFound it.\n")
      assert {_path, "research"} = find(root)
    end
  end
end
