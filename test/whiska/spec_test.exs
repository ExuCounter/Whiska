defmodule Whiska.SpecTest do
  @moduledoc """
  The spec file a mouse writes after grilling stays out of git.

  Asked of real git: what matters is that the owl, which removes only a worktree
  `git status` reads as clean (ADR-0061), still removes one holding a spec.
  """
  use ExUnit.Case, async: true

  alias Whiska.Git
  alias Whiska.Spec
  alias Whiska.Test.GitRepo

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-spec-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    repo = GitRepo.create(root)
    worktree = GitRepo.worktree(repo, "feat-a")
    File.write!(Path.join(worktree, Spec.filename()), "## Problem Statement\n")
    {:ok, repo: repo, worktree: worktree}
  end

  test "an untracked spec alone leaves a worktree dirty", %{worktree: worktree} do
    assert {:ok, false} = Git.clean?(worktree)
  end

  test "once ignored, a worktree holding its spec reads clean and can be removed", %{
    repo: repo,
    worktree: worktree
  } do
    assert :ok = Spec.ignore(repo.checkout)

    assert {:ok, true} = Git.clean?(worktree)
    assert :ok = Git.remove_worktree(repo.checkout, worktree)
    refute File.exists?(worktree)
  end

  test "ignores it at the root only, so a file of that name deeper down stays visible", %{
    repo: repo,
    worktree: worktree
  } do
    Spec.ignore(repo.checkout)
    assert {:ok, true} = Git.clean?(worktree)

    File.mkdir_p!(Path.join(worktree, "docs"))
    File.write!(Path.join([worktree, "docs", Spec.filename()]), "someone's own")

    assert {:ok, false} = Git.clean?(worktree)
  end

  test "is written once however often it runs, beside what was there", %{repo: repo} do
    exclude = Path.join(repo.checkout, ".git/info/exclude")
    File.write!(exclude, "# mine\n*.local")

    Spec.ignore(repo.checkout)
    Spec.ignore(repo.checkout)

    assert File.read!(exclude) == "# mine\n*.local\n#{Spec.exclude_line()}\n"
  end

  test "creates the exclude file when git has none", %{repo: repo} do
    File.rm_rf!(Path.join(repo.checkout, ".git/info"))

    assert :ok = Spec.ignore(repo.checkout)
    assert File.read!(Path.join(repo.checkout, ".git/info/exclude")) == "#{Spec.exclude_line()}\n"
  end

  test "is an error, not a guess, when the checkout has no git directory", %{repo: repo} do
    assert {:error, _} = Spec.ignore(Path.join(repo.root, "not-a-checkout"))
  end
end
