defmodule Whiska.GitTest do
  @moduledoc """
  The local git questions cleanup is allowed to act on (ADR-0061).

  Every one of them is asked of real git in a real repo: these are the four
  preconditions, and a fake of git would be a fake of the only thing keeping a
  folder from being removed when it should not be.
  """
  use ExUnit.Case, async: true

  alias Whiska.Git
  alias Whiska.Test.GitRepo

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-git-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, repo: GitRepo.create(root)}
  end

  describe "base/1" do
    test "is what origin/HEAD points at", %{repo: repo} do
      assert {:ok, "main"} = Git.base(repo.checkout)
    end

    test "falls back to the one local branch that looks like a base", %{repo: repo} do
      GitRepo.git!(repo.checkout, ["remote", "remove", "origin"])
      assert {:ok, "main"} = Git.base(repo.checkout)
    end

    test "is unknown when neither says, and unknown is never permission", %{repo: repo} do
      GitRepo.git!(repo.checkout, ["remote", "remove", "origin"])
      GitRepo.git!(repo.checkout, ["branch", "-m", "main", "trunk"])
      assert {:error, :ambiguous_base} = Git.base(repo.checkout)
    end

    test "is an error in a folder that is not a git repo" do
      assert {:error, _} = Git.base(System.tmp_dir!() |> Path.join("not-a-repo"))
    end
  end

  describe "head_branch/1" do
    test "names the branch a worktree is on", %{repo: repo} do
      path = GitRepo.worktree(repo, "feat-a")
      assert {:ok, "feat-a"} = Git.head_branch(path)
    end

    test "refuses a detached head", %{repo: repo} do
      path = GitRepo.worktree(repo, "feat-a")
      GitRepo.git!(path, ["checkout", "--detach"])
      assert {:error, :detached} = Git.head_branch(path)
    end
  end

  describe "merged?/3" do
    test "false while the branch is only pushed", %{repo: repo} do
      path = GitRepo.worktree(repo, "feat-a")
      assert {:ok, false} = Git.merged?(repo.checkout, path, "main")
    end

    test "true once it has landed in the base", %{repo: repo} do
      path = GitRepo.worktree(repo, "feat-a")
      GitRepo.land(repo, "feat-a")
      assert {:ok, true} = Git.merged?(repo.checkout, path, "main")
    end

    test "true for a base that exists only as a remote branch", %{repo: repo} do
      path = GitRepo.worktree(repo, "feat-a")
      GitRepo.land(repo, "feat-a")
      GitRepo.git!(repo.checkout, ["checkout", "--detach"])
      GitRepo.git!(repo.checkout, ["branch", "-D", "main"])
      assert {:ok, true} = Git.merged?(repo.checkout, path, "main")
    end

    test "is an error when the base names nothing", %{repo: repo} do
      path = GitRepo.worktree(repo, "feat-a")
      assert {:error, _} = Git.merged?(repo.checkout, path, "no-such-base")
    end
  end

  describe "clean?/1" do
    test "true with nothing to save", %{repo: repo} do
      path = GitRepo.worktree(repo, "feat-a")
      assert {:ok, true} = Git.clean?(path)
    end

    test "false on an uncommitted change", %{repo: repo} do
      path = GitRepo.worktree(repo, "feat-a")
      File.write!(Path.join(path, "feat-a.md"), "changed")
      assert {:ok, false} = Git.clean?(path)
    end

    test "false on an untracked file, which is work nobody saved", %{repo: repo} do
      path = GitRepo.worktree(repo, "feat-a")
      GitRepo.dirty!(path)
      assert {:ok, false} = Git.clean?(path)
    end
  end

  describe "unpushed?/2" do
    test "false when every commit is on a remote", %{repo: repo} do
      path = GitRepo.worktree(repo, "feat-a")
      assert {:ok, false} = Git.unpushed?(path, "feat-a")
    end

    test "true when the branch was never pushed", %{repo: repo} do
      path = GitRepo.worktree(repo, "feat-b", push: false)
      assert {:ok, true} = Git.unpushed?(path, "feat-b")
    end

    test "true for a commit made after the push", %{repo: repo} do
      path = GitRepo.worktree(repo, "feat-a")
      GitRepo.commit!(path, "later.md", "after the push")
      assert {:ok, true} = Git.unpushed?(path, "feat-a")
    end
  end

  describe "remove_worktree/2" do
    test "takes the folder down and forgets the worktree", %{repo: repo} do
      path = GitRepo.worktree(repo, "feat-a")
      GitRepo.land(repo, "feat-a")
      assert :ok = Git.remove_worktree(repo.checkout, path)
      refute File.dir?(path)
      refute GitRepo.git!(repo.checkout, ["worktree", "list"]) =~ "feat-a"
    end

    test "refuses a dirty worktree rather than forcing it", %{repo: repo} do
      path = GitRepo.worktree(repo, "feat-a")
      GitRepo.dirty!(path)
      assert {:error, _} = Git.remove_worktree(repo.checkout, path)
      assert File.dir?(path)
    end
  end

  describe "delete_branch/2" do
    test "deletes a merged branch", %{repo: repo} do
      path = GitRepo.worktree(repo, "feat-a")
      GitRepo.land(repo, "feat-a")
      :ok = Git.remove_worktree(repo.checkout, path)
      assert :ok = Git.delete_branch(repo.checkout, "feat-a")
      refute GitRepo.git!(repo.checkout, ["branch", "--list"]) =~ "feat-a"
    end

    test "refuses a branch whose commits are nowhere else — never -D", %{repo: repo} do
      path = GitRepo.worktree(repo, "feat-b", push: false)
      :ok = Git.remove_worktree(repo.checkout, path)
      assert {:error, _} = Git.delete_branch(repo.checkout, "feat-b")
      assert GitRepo.git!(repo.checkout, ["branch", "--list"]) =~ "feat-b"
    end

    test "-d still deletes an unmerged branch that is pushed, so it is not the merge check",
         %{repo: repo} do
      path = GitRepo.worktree(repo, "feat-a")
      :ok = Git.remove_worktree(repo.checkout, path)
      assert :ok = Git.delete_branch(repo.checkout, "feat-a")
    end
  end
end
