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

  describe "base_of/2" do
    test "no recorded base is the default branch", %{repo: repo} do
      assert {:ok, "main"} = Git.base_of(repo.checkout, nil)
    end

    test "a recorded base is the base, whatever the default says", %{repo: repo} do
      GitRepo.git!(repo.checkout, ["branch", "staging"])
      assert {:ok, "main"} = Git.base(repo.checkout)
      assert {:ok, "staging"} = Git.base_of(repo.checkout, "staging")
    end

    test "a base whose name is not plain is refused, recorded or not", %{repo: repo} do
      assert {:error, :unsafe_base} = Git.base_of(repo.checkout, "x$(cmd)")
      GitRepo.git!(repo.checkout, ["remote", "remove", "origin"])
      GitRepo.git!(repo.checkout, ["branch", "-m", "main", "master"])
      GitRepo.git!(repo.checkout, ["branch", "-m", "master", "x$(cmd)"])
      assert {:error, _} = Git.base_of(repo.checkout, nil)
    end

    test "a recorded base that is gone is an error, never main", %{repo: repo} do
      assert {:error, {:base_gone, "staging"}} = Git.base_of(repo.checkout, "staging")
    end
  end

  describe "branch_head/2 and reached_by_merge?/3 (ADR-0064)" do
    test "names the commit a branch points at", %{repo: repo} do
      GitRepo.worktree(repo, "feat-a")
      head = String.trim(GitRepo.git!(repo.checkout, ["rev-parse", "refs/heads/feat-a"]))

      assert {:ok, ^head} = Git.branch_head(repo.checkout, "feat-a")
    end

    test "a branch nobody carries is unknown, never a guess", %{repo: repo} do
      assert {:error, :no_such_branch} = Git.branch_head(repo.checkout, "feat-gone")
      assert {:error, :no_such_branch} = Git.branch_head(repo.checkout, "feat-a^{tree}")
    end

    test "a merged branch was reached by a merge", %{repo: repo} do
      GitRepo.worktree(repo, "feat-a")
      GitRepo.land(repo, "feat-a")
      {:ok, head} = Git.branch_head(repo.checkout, "feat-a")

      assert {:ok, true} = Git.reached_by_merge?(repo.checkout, head, "main")
    end

    test "a branch that never left the base's own line was not", %{repo: repo} do
      GitRepo.worktree(repo, "feat-a", commit: false)
      {:ok, head} = Git.branch_head(repo.checkout, "feat-a")

      assert {:ok, true} = Git.ancestor?(repo.checkout, head, "main")
      assert {:ok, false} = Git.reached_by_merge?(repo.checkout, head, "main")
    end

    test "nor was one cut off the base and left behind by it", %{repo: repo} do
      GitRepo.worktree(repo, "feat-a", commit: false)
      {:ok, head} = Git.branch_head(repo.checkout, "feat-a")
      GitRepo.commit!(repo.checkout, "later.md", "moved on")

      assert {:ok, false} = Git.reached_by_merge?(repo.checkout, head, "main")
    end

    test "a base that resolves to nothing is an error, not a false", %{repo: repo} do
      GitRepo.worktree(repo, "feat-a")
      {:ok, head} = Git.branch_head(repo.checkout, "feat-a")

      assert {:error, {:no_base_ref, "trunk"}} =
               Git.reached_by_merge?(repo.checkout, head, "trunk")
    end
  end

  describe "in_base?/3 — a trial merge that would change nothing" do
    test "a branch whose commits were copied onto a base that moved on is in it",
         %{repo: repo} do
      GitRepo.worktree(repo, "feat-a")
      GitRepo.commit!(repo.checkout, "later.md", "moved on")
      GitRepo.cherry_pick(repo, "feat-a")
      {:ok, head} = Git.branch_head(repo.checkout, "feat-a")

      assert {:ok, false} = Git.ancestor?(repo.checkout, head, "main")
      assert {:ok, true} = Git.in_base?(repo.checkout, head, "main")
    end

    test "so is a squashed one", %{repo: repo} do
      path = GitRepo.worktree(repo, "feat-a")
      GitRepo.commit!(path, "more.md", "second")
      GitRepo.squash(repo, "feat-a")
      {:ok, head} = Git.branch_head(repo.checkout, "feat-a")

      assert {:ok, true} = Git.in_base?(repo.checkout, head, "main")
    end

    test "a branch whose work the base does not have is not", %{repo: repo} do
      GitRepo.worktree(repo, "feat-a")
      {:ok, head} = Git.branch_head(repo.checkout, "feat-a")

      assert {:ok, false} = Git.in_base?(repo.checkout, head, "main")
    end

    test "only part of a branch copied over is not", %{repo: repo} do
      path = GitRepo.worktree(repo, "feat-a")
      first = String.trim(GitRepo.git!(path, ["rev-parse", "HEAD"]))
      GitRepo.commit!(path, "more.md", "second")
      GitRepo.git!(repo.checkout, ["cherry-pick", first])
      {:ok, head} = Git.branch_head(repo.checkout, "feat-a")

      assert {:ok, false} = Git.in_base?(repo.checkout, head, "main")
    end

    test "a branch with no commits of its own never is, though merging it changes nothing",
         %{repo: repo} do
      GitRepo.worktree(repo, "research-a", commit: false)
      GitRepo.commit!(repo.checkout, "later.md", "moved on")
      {:ok, head} = Git.branch_head(repo.checkout, "research-a")

      assert {:ok, false} = Git.in_base?(repo.checkout, head, "main")
    end

    test "a branch whose only commit merges the base in is not", %{repo: repo} do
      path = GitRepo.worktree(repo, "feat-a", commit: false)
      GitRepo.commit!(repo.checkout, "later.md", "moved on")
      GitRepo.git!(path, ["merge", "--no-ff", "-m", "merge main", "main"])
      {:ok, head} = Git.branch_head(repo.checkout, "feat-a")

      assert {:ok, false} = Git.ancestor?(repo.checkout, head, "main")
      assert {:ok, false} = Git.in_base?(repo.checkout, head, "main")
    end

    test "a branch whose commits add up to no change is not", %{repo: repo} do
      path = GitRepo.worktree(repo, "feat-a")
      GitRepo.git!(path, ["revert", "--no-edit", "HEAD"])
      GitRepo.commit!(repo.checkout, "later.md", "moved on")
      {:ok, head} = Git.branch_head(repo.checkout, "feat-a")

      assert {:ok, false} = Git.in_base?(repo.checkout, head, "main")
    end

    test "a branch whose change conflicts with the base is not", %{repo: repo} do
      path = GitRepo.worktree(repo, "feat-a", commit: false)
      GitRepo.commit!(path, "README.md", "branch says this")
      GitRepo.commit!(repo.checkout, "README.md", "base says that")
      {:ok, head} = Git.branch_head(repo.checkout, "feat-a")

      assert {:ok, false} = Git.in_base?(repo.checkout, head, "main")
    end

    test "a base that resolves to nothing is an error, not a false", %{repo: repo} do
      GitRepo.worktree(repo, "feat-a")
      {:ok, head} = Git.branch_head(repo.checkout, "feat-a")

      assert {:error, {:no_base_ref, "trunk"}} = Git.in_base?(repo.checkout, head, "trunk")
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

    test "deletes a branch landed as copies only when told it is landed, which -d refuses",
         %{repo: repo} do
      path = GitRepo.worktree(repo, "feat-b", push: false)
      GitRepo.commit!(repo.checkout, "later.md", "moved on")
      GitRepo.cherry_pick(repo, "feat-b")
      :ok = Git.remove_worktree(repo.checkout, path)

      {:ok, head} = Git.branch_head(repo.checkout, "feat-b")

      assert {:error, _} = Git.delete_branch(repo.checkout, "feat-b")
      assert :ok = Git.delete_branch(repo.checkout, "feat-b", {:in_base, head})
      refute GitRepo.git!(repo.checkout, ["branch", "--list"]) =~ "feat-b"
    end

    test "keeps a branch landed as copies that moved since it was checked", %{repo: repo} do
      path = GitRepo.worktree(repo, "feat-b", push: false)
      GitRepo.commit!(repo.checkout, "later.md", "moved on")
      GitRepo.cherry_pick(repo, "feat-b")
      {:ok, checked} = Git.branch_head(repo.checkout, "feat-b")
      GitRepo.commit!(path, "late.md", "one more")
      :ok = Git.remove_worktree(repo.checkout, path)

      assert {:error, _} = Git.delete_branch(repo.checkout, "feat-b", {:in_base, checked})
      assert GitRepo.git!(repo.checkout, ["branch", "--list"]) =~ "feat-b"
    end

    test "-d still deletes an unmerged branch that is pushed, so it is not the merge check",
         %{repo: repo} do
      path = GitRepo.worktree(repo, "feat-a")
      :ok = Git.remove_worktree(repo.checkout, path)
      assert :ok = Git.delete_branch(repo.checkout, "feat-a")
    end
  end

  # The branch is a mouse's work, and the diff is read for the person to review.
  describe "branch_diff/3" do
    defp tripwire(repo) do
      ran = Path.join(repo.root, "ran")
      script = Path.join(repo.root, "differ.sh")
      File.write!(script, "#!/bin/sh\ntouch #{ran}\n")
      File.chmod!(script, 0o755)
      {script, ran}
    end

    test "is the branch's change from where it left the base", %{repo: repo} do
      GitRepo.worktree(repo, "feat-d", push: false)

      assert {:ok, %{base: "main", diff: diff}} = Git.branch_diff(repo.checkout, "feat-d")
      assert diff =~ "+++ b/feat-d.md"
      assert diff =~ "+work"
    end

    test "runs no diff program or text conversion that git's config names", %{repo: repo} do
      GitRepo.worktree(repo, "feat-e", push: false)
      {script, ran} = tripwire(repo)
      GitRepo.git!(repo.checkout, ["config", "diff.external", script])
      GitRepo.git!(repo.checkout, ["config", "diff.conv.textconv", script])
      File.write!(Path.join(repo.checkout, ".git/info/attributes"), "* diff=conv\n")

      assert {:ok, %{diff: diff}} = Git.branch_diff(repo.checkout, "feat-e")
      assert diff =~ "+work"
      refute File.exists?(ran)
    end

    test "runs none inside a submodule the branch moved either", %{repo: repo} do
      sub = Path.join(repo.root, "sub")
      File.mkdir_p!(sub)
      GitRepo.git!(sub, ["init", "-b", "main"])
      GitRepo.commit!(sub, "s.md", "one")

      GitRepo.git!(repo.checkout, [
        "-c",
        "protocol.file.allow=always",
        "submodule",
        "add",
        sub,
        "sub"
      ])

      GitRepo.git!(repo.checkout, ["commit", "-m", "add sub"])

      GitRepo.git!(repo.checkout, ["checkout", "-b", "feat-s"])
      GitRepo.commit!(Path.join(repo.checkout, "sub"), "s.md", "two")
      GitRepo.git!(repo.checkout, ["add", "sub"])
      GitRepo.git!(repo.checkout, ["commit", "-m", "move sub"])
      GitRepo.git!(repo.checkout, ["checkout", "main"])

      {script, ran} = tripwire(repo)
      GitRepo.git!(repo.checkout, ["config", "diff.submodule", "diff"])
      GitRepo.git!(Path.join(repo.checkout, "sub"), ["config", "diff.external", script])

      assert {:ok, %{diff: diff}} = Git.branch_diff(repo.checkout, "feat-s")
      assert diff =~ "sub"
      refute File.exists?(ran)
    end
  end
end
