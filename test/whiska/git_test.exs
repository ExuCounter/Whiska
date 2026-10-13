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

  describe "fetch_base/3 and landing_refs/2" do
    test "a merge on the forge reaches the fetched base after a fetch, never the local one",
         %{repo: repo} do
      path = GitRepo.worktree(repo, "feat-a")
      {:ok, head} = Git.head(path)
      local = GitRepo.git!(repo.checkout, ["rev-parse", "main"])
      GitRepo.merge_on_forge(repo, "feat-a")

      assert {:ok, [{:local, "refs/heads/main"}]} = Git.landing_refs(repo.checkout, "main")
      assert :ok = Git.fetch_base(repo.checkout, "main")

      assert {:ok,
              [{:local, "refs/heads/main"}, {:fetched, "refs/remotes/origin/main"} = fetched]} =
               Git.landing_refs(repo.checkout, "main")

      assert {:ok, true} = Git.ancestor?(repo.checkout, head, fetched)
      assert {:ok, true} = Git.reached_by_merge?(repo.checkout, head, fetched)
      assert {:ok, false} = Git.ancestor?(repo.checkout, head, "main")
      assert GitRepo.git!(repo.checkout, ["rev-parse", "main"]) == local
    end

    test "a squash on the forge is in the fetched base", %{repo: repo} do
      path = GitRepo.worktree(repo, "feat-a")
      GitRepo.commit!(path, "more.md", "second")
      GitRepo.git!(path, ["push", "--quiet", "origin", "feat-a"])
      {:ok, head} = Git.head(path)
      GitRepo.merge_on_forge(repo, "feat-a", squash: true)
      :ok = Git.fetch_base(repo.checkout, "main")

      {:ok, [_local, fetched]} = Git.landing_refs(repo.checkout, "main")
      assert {:ok, false} = Git.ancestor?(repo.checkout, head, fetched)
      assert {:ok, true} = Git.in_base?(repo.checkout, head, fetched)
    end

    test "fetches from the remote the base tracks", %{repo: repo} do
      GitRepo.git!(repo.checkout, ["remote", "add", "upstream", repo.remote])
      GitRepo.git!(repo.checkout, ["fetch", "--quiet", "upstream"])
      GitRepo.git!(repo.checkout, ["branch", "--set-upstream-to=upstream/main", "main"])
      before = GitRepo.git!(repo.checkout, ["rev-parse", "origin/main"])
      GitRepo.worktree(repo, "feat-a")
      GitRepo.merge_on_forge(repo, "feat-a")

      assert :ok = Git.fetch_base(repo.checkout, "main")

      assert {:ok, [_local, {:fetched, "refs/remotes/upstream/main"}]} =
               Git.landing_refs(repo.checkout, "main")

      assert GitRepo.git!(repo.checkout, ["rev-parse", "origin/main"]) == before
    end

    test "a base with no remote has nothing to fetch, and is read where it is", %{repo: repo} do
      GitRepo.git!(repo.checkout, ["remote", "remove", "origin"])

      assert {:error, :no_remote} = Git.fetch_base(repo.checkout, "main")
      assert {:ok, [{:local, "refs/heads/main"}]} = Git.landing_refs(repo.checkout, "main")
    end

    test "a remote that cannot be reached is an error, and the fetched base stays put",
         %{repo: repo} do
      before = GitRepo.git!(repo.checkout, ["rev-parse", "origin/main"])
      GitRepo.git!(repo.checkout, ["remote", "set-url", "origin", Path.join(repo.root, "gone")])

      assert {:error, _} = Git.fetch_base(repo.checkout, "main")
      assert GitRepo.git!(repo.checkout, ["rev-parse", "origin/main"]) == before
    end

    test "a fetch that outlives its deadline is killed with what it started, and the person's ssh command is used",
         %{repo: repo} do
      ssh = Path.join(repo.root, "slow-ssh")
      File.write!(ssh, "#!/bin/sh\nexec sleep 7.317\n")
      File.chmod!(ssh, 0o755)
      GitRepo.git!(repo.checkout, ["config", "core.sshCommand", ssh])
      GitRepo.git!(repo.checkout, ["remote", "set-url", "origin", "ssh://example.invalid/r.git"])

      {micros, result} = :timer.tc(fn -> Git.fetch_base(repo.checkout, "main", 300) end)

      assert result == {:error, :timeout}
      assert micros < 3_000_000
      assert {_none, 1} = System.cmd("pgrep", ["-f", "7.317"])
    end

    test "a remote that asks for a password fails, and no password program is run",
         %{repo: repo} do
      asked = Path.join(repo.root, "asked")
      askpass = Path.join(repo.root, "askpass")
      File.write!(askpass, "#!/bin/sh\ntouch '#{asked}'\necho secret\n")
      File.chmod!(askpass, 0o755)
      GitRepo.git!(repo.checkout, ["config", "core.askPass", askpass])
      GitRepo.git!(repo.checkout, ["config", "credential.helper", ""])
      url = "http://127.0.0.1:#{asks_for_a_password()}/r.git"
      GitRepo.git!(repo.checkout, ["remote", "set-url", "origin", url])

      assert {:error, _} = Git.fetch_base(repo.checkout, "main", 10_000)
      refute File.exists?(asked)
    end

    test "the base's upstream is its own, never a branch named under it", %{repo: repo} do
      GitRepo.git!(repo.checkout, ["checkout", "--quiet", "-b", "hotfix"])
      GitRepo.commit!(repo.checkout, "fix.md", "fix")
      GitRepo.git!(repo.checkout, ["push", "--quiet", "origin", "hotfix"])
      GitRepo.git!(repo.checkout, ["branch", "-D", "main"])
      GitRepo.git!(repo.checkout, ["branch", "--track", "main/x", "origin/hotfix"])

      assert {:ok, [{:local, "refs/remotes/origin/main"}]} =
               Git.landing_refs(repo.checkout, "main")
    end

    test "a base tracking something that is no remote's branch has no fetched copy",
         %{repo: repo} do
      GitRepo.worktree(repo, "feat-a")
      GitRepo.merge_on_forge(repo, "feat-a")
      GitRepo.git!(repo.checkout, ["fetch", "--quiet", "origin"])
      GitRepo.git!(repo.checkout, ["branch", "--set-upstream-to=feat-a", "main"])

      assert {:ok, [{:local, "refs/heads/main"}]} = Git.landing_refs(repo.checkout, "main")
      assert {:error, _} = Git.fetch_base(repo.checkout, "main")
    end

    test "a landing check never fetches what a partial clone left out", %{repo: repo} do
      GitRepo.git!(repo.remote, ["config", "uploadpack.allowFilter", "true"])
      GitRepo.git!(repo.remote, ["config", "uploadpack.allowAnySHA1InWant", "true"])
      partial = Path.join(repo.root, "partial")
      remote = "file://" <> repo.remote
      GitRepo.git!(repo.root, ["clone", "--quiet", "--filter=blob:none", remote, partial])
      GitRepo.git!(partial, ["checkout", "--quiet", "-b", "feat-a"])
      GitRepo.commit!(partial, "README.md", "hello\nfrom the branch\n")
      GitRepo.commit!(repo.checkout, "README.md", "hello\nfrom main\n")
      GitRepo.git!(repo.checkout, ["push", "--quiet", "origin", "main"])
      :ok = Git.fetch_base(partial, "main")
      {:ok, head} = Git.head(partial)
      {:ok, [_local, fetched]} = Git.landing_refs(partial, "main")
      missing = ["rev-list", "--objects", "--missing=print", "refs/remotes/origin/main"]
      left_out = GitRepo.git!(partial, missing)
      assert left_out =~ "?"

      refute match?({:ok, true}, Git.in_base?(partial, head, fetched))
      assert GitRepo.git!(partial, missing) == left_out
    end
  end

  defp asks_for_a_password do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listen)
    server = spawn(fn -> unauthorized(listen) end)
    :ok = :gen_tcp.controlling_process(listen, server)
    on_exit(fn -> Process.exit(server, :kill) end)
    port
  end

  defp unauthorized(listen) do
    with {:ok, socket} <- :gen_tcp.accept(listen) do
      _ = :gen_tcp.recv(socket, 0, 2_000)

      :gen_tcp.send(
        socket,
        "HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm=\"r\"\r\n" <>
          "Content-Length: 0\r\nConnection: close\r\n\r\n"
      )

      :gen_tcp.close(socket)
      unauthorized(listen)
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

    test "a branch deleted as landed leaves its settings, so only the branch goes",
         %{repo: repo} do
      path = GitRepo.worktree(repo, "feat-b")
      GitRepo.merge_on_forge(repo, "feat-b", squash: true)
      :ok = Git.fetch_base(repo.checkout, "main")
      :ok = Git.remove_worktree(repo.checkout, path)
      {:ok, head} = Git.branch_head(repo.checkout, "feat-b")

      assert :ok = Git.delete_branch(repo.checkout, "feat-b", {:in_base, head})
      refute GitRepo.git!(repo.checkout, ["branch", "--list"]) =~ "feat-b"
      assert GitRepo.git!(repo.checkout, ["config", "branch.feat-b.remote"]) =~ "origin"
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
