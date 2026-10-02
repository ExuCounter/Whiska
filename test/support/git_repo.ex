defmodule Whiska.Test.GitRepo do
  @moduledoc """
  A real git repo on disk, for the cleanup tests.

  Whether a branch is merged, a worktree clean and a commit pushed are git's
  questions and nobody else's (ADR-0058), so the tests ask real git rather than
  a fake of it — the mocking this codebase allows is confined to the herdr
  boundary (ADR-0031), and git is not that boundary.

  Every repo is built with its own config, so the person's own `~/.gitconfig`,
  their hooks and their default branch name cannot change what a test means.
  """

  @env [
    {"GIT_CONFIG_GLOBAL", "/dev/null"},
    {"GIT_CONFIG_SYSTEM", "/dev/null"},
    {"GIT_AUTHOR_NAME", "Test"},
    {"GIT_AUTHOR_EMAIL", "test@example.com"},
    {"GIT_COMMITTER_NAME", "Test"},
    {"GIT_COMMITTER_EMAIL", "test@example.com"}
  ]

  @doc "A bare remote, a main checkout on `main` with one commit, and `origin/HEAD` set."
  def create(root) do
    remote = Path.join(root, "remote.git")
    checkout = Path.join(root, "repo")
    File.mkdir_p!(remote)
    File.mkdir_p!(checkout)

    git!(remote, ["init", "--bare", "-b", "main"])
    git!(checkout, ["init", "-b", "main"])
    commit!(checkout, "README.md", "hello")
    git!(checkout, ["remote", "add", "origin", remote])
    git!(checkout, ["push", "-u", "origin", "main"])
    git!(checkout, ["remote", "set-head", "origin", "main"])

    %{root: root, remote: remote, checkout: checkout}
  end

  @doc "A worktree on a new branch, with one commit of its own, pushed unless `push: false`."
  def worktree(repo, branch, opts \\ []) do
    path = Path.join([repo.root, "worktrees", branch])
    git!(repo.checkout, ["worktree", "add", "-b", branch, path])
    commit!(path, "#{branch}.md", "work")
    if Keyword.get(opts, :push, true), do: git!(path, ["push", "-u", "origin", branch])
    path
  end

  @doc "Merge a branch into `main` and push, which is what makes it cleanable."
  def land(repo, branch, opts \\ []) do
    git!(repo.checkout, ["merge", "--no-ff", "-m", "merge #{branch}", branch])
    if Keyword.get(opts, :push, true), do: git!(repo.checkout, ["push", "origin", "main"])
    :ok
  end

  @doc "Write a file and commit it."
  def commit!(dir, file, contents) do
    File.write!(Path.join(dir, file), contents)
    git!(dir, ["add", file])
    git!(dir, ["commit", "-m", "add #{file}"])
  end

  @doc "Leave an uncommitted change behind."
  def dirty!(dir), do: File.write!(Path.join(dir, "scratch.txt"), "unsaved")

  def git!(dir, args) do
    case System.cmd("git", args, cd: dir, env: @env, stderr_to_stdout: true) do
      {out, 0} -> out
      {out, code} -> raise "git #{Enum.join(args, " ")} in #{dir} failed (#{code}): #{out}"
    end
  end
end
