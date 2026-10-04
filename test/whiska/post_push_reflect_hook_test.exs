defmodule Whiska.PostPushReflectHookTest do
  @moduledoc """
  `.claude/hooks/post-push-reflect.sh`, this repo's own reflection nudge. It is
  shipped nowhere — `whiska init` never carries it — but it is still code with a
  rule in it, so it runs here for real: the real script, a real repo from
  `Whiska.Test.GitRepo`, a real push, and the hook's stdout read back.

  The rule: a branch reflects before it finishes, so a push whose new commits
  all arrived through merges is somebody else's reflected work and stays quiet.
  A commit written on the pushed branch itself still nudges. A squash or a
  fast-forward leaves no merge behind and nudges too — noisy on purpose, since a
  nudge that never fires is worse than one that fires too often.
  """
  use ExUnit.Case, async: true

  alias Whiska.Test.GitRepo

  @hook Path.expand(".claude/hooks/post-push-reflect.sh")

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-reflect-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, repo: GitRepo.create(root)}
  end

  test "a push whose new commits all came in through merges stays quiet", %{repo: repo} do
    GitRepo.worktree(repo, "feat-a")
    GitRepo.worktree(repo, "feat-b")
    GitRepo.land(repo, "feat-a")
    assert hook(repo) == :quiet

    GitRepo.land(repo, "feat-b")
    assert hook(repo) == :quiet
  end

  test "a push carrying a commit written on main still nudges", %{repo: repo} do
    GitRepo.worktree(repo, "feat-a")
    GitRepo.git!(repo.checkout, ["merge", "--no-ff", "-m", "merge feat-a", "feat-a"])
    GitRepo.commit!(repo.checkout, "fix.md", "written here")
    GitRepo.git!(repo.checkout, ["push", "origin", "main"])

    assert hook(repo) == :nudge
  end

  test "a quiet merge push leaves the next push free to nudge", %{repo: repo} do
    GitRepo.worktree(repo, "feat-a")
    GitRepo.land(repo, "feat-a")
    assert hook(repo) == :quiet

    GitRepo.commit!(repo.checkout, "fix.md", "written here")
    GitRepo.git!(repo.checkout, ["push", "origin", "main"])
    assert hook(repo) == :nudge
  end

  test "a fast-forwarded branch leaves no merge behind, so it nudges", %{repo: repo} do
    GitRepo.worktree(repo, "feat-a")
    GitRepo.git!(repo.checkout, ["merge", "--ff-only", "feat-a"])
    GitRepo.git!(repo.checkout, ["push", "origin", "main"])

    assert hook(repo) == :nudge
  end

  test "a squashed branch is one plain commit, so it nudges", %{repo: repo} do
    GitRepo.worktree(repo, "feat-a")
    GitRepo.git!(repo.checkout, ["merge", "--squash", "feat-a"])
    GitRepo.git!(repo.checkout, ["commit", "-m", "squash feat-a"])
    GitRepo.git!(repo.checkout, ["push", "origin", "main"])

    assert hook(repo) == :nudge
  end

  test "a branch's first push, with nothing to compare against, nudges", %{repo: repo} do
    path = GitRepo.worktree(repo, "feat-a")

    assert hook(%{checkout: path}) == :nudge
  end

  test "pushing the same commits again stays quiet", %{repo: repo} do
    GitRepo.commit!(repo.checkout, "fix.md", "written here")
    GitRepo.git!(repo.checkout, ["push", "origin", "main"])
    assert hook(repo) == :nudge
    assert hook(repo) == :quiet
  end

  defp hook(repo, command \\ "git push origin main") do
    payload = JSON.encode!(%{"tool_input" => %{"command" => command}})
    payload_file = Path.join(repo.checkout, "../payload-#{System.unique_integer([:positive])}")
    File.write!(payload_file, payload)

    {out, 0} =
      System.cmd("bash", ["-c", ~s|bash "#{@hook}" < "#{payload_file}"|],
        cd: repo.checkout,
        env: [{"GIT_CONFIG_GLOBAL", "/dev/null"}, {"GIT_CONFIG_SYSTEM", "/dev/null"}]
      )

    if out =~ "additionalContext", do: :nudge, else: :quiet
  end
end
