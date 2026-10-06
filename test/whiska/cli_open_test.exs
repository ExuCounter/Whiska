defmodule Whiska.CLIOpenTest do
  @moduledoc """
  `whiska open <question-id|branch>` — take the person to a mouse's own pane
  (ADR-0043's 2026-10-06 note), faked at the herdr boundary (ADR-0031) over a
  real git repo, since what is left of a mouse is git's to say.
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
    root = Path.join(System.tmp_dir!(), "whiska-open-#{System.unique_integer([:positive])}")
    repo = GitRepo.create(root)
    path = GitRepo.worktree(repo, "feat-a")

    {:ok, handle} = Storage.open(repo.checkout)
    {:ok, _} = Storage.record_mouse(%{mouse_id: "m1", path: path, branch: "feat-a"})

    {:ok, q} =
      Storage.record_question(%{
        mouse_id: "m1",
        text: "done",
        kind: "done",
        status: "closed"
      })

    Storage.close(handle)

    was = System.get_env("HERDR_SOCKET_PATH")
    System.put_env("HERDR_SOCKET_PATH", @socket)

    on_exit(fn ->
      if was,
        do: System.put_env("HERDR_SOCKET_PATH", was),
        else: System.delete_env("HERDR_SOCKET_PATH")

      File.rm_rf!(root)
    end)

    {:ok, repo: repo, path: path, id: to_string(q.id)}
  end

  defp open(arg, repo) do
    out = capture_io(fn -> send(self(), {:code, CLI.run(["open", arg], repo.checkout)}) end)
    assert_received {:code, code}
    {code, out}
  end

  test "focuses the pane working inside the worktree, found by its folder", ctx do
    expect(Herdr, :list_panes, fn @socket ->
      {:ok,
       [
         %{pane_id: "w1:p1", cwd: ctx.repo.checkout, agent: "claude"},
         %{pane_id: "w2:p3", cwd: Path.join(ctx.path, "lib"), agent: "claude"}
       ]}
    end)

    expect(Herdr, :focus, fn @socket, "w2:p3" -> :ok end)

    assert {0, out} = open(ctx.id, ctx.repo)
    assert out =~ "w2:p3"
  end

  test "a branch name works as well as a question id", ctx do
    expect(Herdr, :list_panes, fn @socket -> {:ok, [%{pane_id: "w2:p3", cwd: ctx.path}]} end)
    expect(Herdr, :focus, fn @socket, "w2:p3" -> :ok end)

    assert {0, _} = open("feat-a", ctx.repo)
  end

  test "a worktree with no workspace is opened in herdr, and says no session runs", ctx do
    expect(Herdr, :list_panes, fn @socket -> {:ok, []} end)
    expect(Herdr, :open_worktree, fn @socket, path -> assert path == ctx.path && :ok end)

    assert {0, out} = open(ctx.id, ctx.repo)
    assert out =~ "no session is running"
  end

  test "a gone worktree with its branch kept says so, with the commit count", ctx do
    GitRepo.git!(ctx.repo.checkout, ["worktree", "remove", "--force", ctx.path])
    expect(Herdr, :list_panes, fn @socket -> {:ok, []} end)

    assert {0, out} = open(ctx.id, ctx.repo)
    assert out =~ "1 commit"
    assert out =~ "Spawn it again"
  end

  test "a branch that is gone landed or was dropped, and exits 0", ctx do
    GitRepo.land(ctx.repo, "feat-a")
    GitRepo.git!(ctx.repo.checkout, ["worktree", "remove", "--force", ctx.path])
    GitRepo.git!(ctx.repo.checkout, ["branch", "-d", "feat-a"])
    expect(Herdr, :list_panes, fn @socket -> {:ok, []} end)

    assert {0, out} = open(ctx.id, ctx.repo)
    assert out =~ "landed or was dropped"
  end

  test "an id or branch nobody knows is an error", ctx do
    err =
      capture_io(:stderr, fn ->
        send(self(), {:code, CLI.run(["open", "nope"], ctx.repo.checkout)})
      end)

    assert_received {:code, 1}
    assert err =~ "nope"
  end
end
