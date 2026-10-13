defmodule Whiska.DropTest do
  @moduledoc """
  `whiska drop` through the CLI, over a real git repo and a fake herdr
  (ADR-0031).
  """
  # Serial: the house opens under the one VM-wide name `Whiska.Repo`, and the
  # test sets HERDR_SOCKET_PATH in the OS env.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import Mox

  alias Whiska.CLI
  alias Whiska.Herdr.Mock, as: Herdr
  alias Whiska.Storage
  alias Whiska.Test.GitRepo

  setup :verify_on_exit!

  @socket "/fake/herdr.sock"

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-drop-#{System.unique_integer([:positive])}")
    repo = GitRepo.create(root)

    was = System.get_env("HERDR_SOCKET_PATH")
    System.put_env("HERDR_SOCKET_PATH", @socket)

    on_exit(fn ->
      if was,
        do: System.put_env("HERDR_SOCKET_PATH", was),
        else: System.delete_env("HERDR_SOCKET_PATH")

      File.rm_rf!(root)
    end)

    {:ok, repo: repo}
  end

  defp mouse(repo, branch, opts) do
    path = GitRepo.worktree(repo, branch, opts)

    Storage.within(repo.checkout, fn ->
      {:ok, _} =
        Storage.record_mouse(%{mouse_id: "m1", path: path, branch: branch, pane: "w2:p3"})
    end)

    stub(Herdr, :worktrees, fn @socket, _checkout ->
      {:ok, [%{path: path, branch: branch, workspace_id: "w2"}]}
    end)

    path
  end

  # herdr removes the worktree the way it does, through git.
  defp herdr_removes(repo, path, call) do
    expect(Herdr, call, fn @socket, "w2" ->
      args = if call == :force_remove_worktree, do: ["--force"], else: []
      GitRepo.git!(repo.checkout, ["worktree", "remove", path | args])
      :ok
    end)
  end

  defp drop(args, repo) do
    parent = self()

    err =
      capture_io(:stderr, fn ->
        out = capture_io(fn -> send(parent, {:code, CLI.run(["drop" | args], repo.checkout)}) end)
        send(parent, {:out, out})
      end)

    assert_received {:code, code}
    assert_received {:out, out}
    {code, out, err}
  end

  defp branch?(repo, branch),
    do: GitRepo.git!(repo.checkout, ["branch", "--list", branch]) != ""

  test "a pushed, clean worktree goes with its workspace and its branch", ctx do
    path = mouse(ctx.repo, "feat-a", [])
    herdr_removes(ctx.repo, path, :remove_worktree)

    assert {0, out, _} = drop(["feat-a"], ctx.repo)
    assert out =~ "feat-a"
    refute File.dir?(path)
    refute branch?(ctx.repo, "feat-a")

    Storage.within(ctx.repo.checkout, fn ->
      assert %{removed_at: %DateTime{}, died_at: %DateTime{}} = Storage.mouse("m1")
    end)
  end

  test "work that would be lost is named, and nothing goes without --force", ctx do
    path = mouse(ctx.repo, "feat-b", push: false)
    GitRepo.dirty!(path)

    assert {1, _, err} = drop(["feat-b"], ctx.repo)
    assert err =~ "add feat-b.md"
    assert err =~ "scratch.txt"
    assert err =~ "--force"
    assert File.dir?(path)
    assert branch?(ctx.repo, "feat-b")

    herdr_removes(ctx.repo, path, :force_remove_worktree)

    assert {0, _, _} = drop(["feat-b", "--force"], ctx.repo)
    refute File.dir?(path)
    refute branch?(ctx.repo, "feat-b")
  end

  test "the hooks spawn carried in from an uncommitted install are no work to lose", ctx do
    path = mouse(ctx.repo, "feat-c", [])

    for root <- [ctx.repo.checkout, path] do
      File.mkdir_p!(Path.join(root, ".claude/hooks"))
      File.write!(Path.join(root, ".claude/settings.json"), "{}\n")
      File.write!(Path.join(root, ".claude/hooks/whiska.sh"), "#!/bin/sh\n")
    end

    herdr_removes(ctx.repo, path, :force_remove_worktree)

    assert {0, _, _} = drop(["feat-c"], ctx.repo)
    refute File.dir?(path)
  end

  test "a branch with no worktree and no branch says there is nothing to drop", ctx do
    stub(Herdr, :worktrees, fn @socket, _checkout -> {:ok, []} end)

    assert {1, _, err} = drop(["feat-none"], ctx.repo)
    assert err =~ "feat-none"
  end
end
