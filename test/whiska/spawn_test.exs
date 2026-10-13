defmodule Whiska.SpawnTest do
  @moduledoc """
  `whiska spawn` through the CLI, over a real git repo and a fake herdr
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
    root = Path.join(System.tmp_dir!(), "whiska-spawn-#{System.unique_integer([:positive])}")
    repo = GitRepo.create(root)
    task = Path.join(root, "task.md")
    File.write!(task, "Make the CSV page sortable by date.\n")

    was = System.get_env("HERDR_SOCKET_PATH")
    System.put_env("HERDR_SOCKET_PATH", @socket)

    on_exit(fn ->
      if was,
        do: System.put_env("HERDR_SOCKET_PATH", was),
        else: System.delete_env("HERDR_SOCKET_PATH")

      File.rm_rf!(root)
    end)

    {:ok, repo: repo, root: root, task: task}
  end

  defp spawn_mouse(args, repo) do
    {out, err} =
      with_stderr(fn -> send(self(), {:code, CLI.run(["spawn" | args], repo.checkout)}) end)

    assert_received {:code, code}
    {code, out, err}
  end

  defp with_stderr(fun) do
    parent = self()

    err =
      capture_io(:stderr, fn ->
        send(parent, {:out, capture_io(fun)})
      end)

    assert_received {:out, out}
    {out, err}
  end

  defp herdr_creates(repo, branch) do
    expect(Herdr, :create_worktree, fn @socket, new ->
      assert new.cwd == repo.checkout
      assert new.branch == branch
      assert new.path == Path.join([repo.checkout, "worktrees", branch])
      GitRepo.git!(repo.checkout, ["worktree", "add", "-b", branch, new.path])
      {:ok, %{workspace_id: "w9", pane_id: "w9:p1"}}
    end)
  end

  defp mouse_on(repo, branch) do
    Storage.within(repo.checkout, fn ->
      Enum.find(Storage.current_mice(), &(&1.branch == branch))
    end)
  end

  test "makes the worktree, shapes the mouse and starts it on the task", ctx do
    herdr_creates(ctx.repo, "feat/csv-sort")

    expect(Herdr, :start_agent, fn @socket, "w9:p1", "feat-csv-sort", args ->
      send(self(), {:args, args})
      {:ok, ["claude" | args]}
    end)

    expect(Herdr, :prompt, fn @socket, "w9:p1", text ->
      send(self(), {:prompt, text})
      :ok
    end)

    assert {0, out, _err} =
             spawn_mouse(["build", "feat/csv-sort", ctx.task, "--model", "opus"], ctx.repo)

    assert out =~ "feat/csv-sort"
    assert_received {:args, args}
    assert ["--model", "opus" | _] = args
    assert Enum.take(args, -2) == ["--append-system-prompt-file", ".whiska-brief.md"]

    brief = File.read!(Path.join([ctx.repo.checkout, "worktrees/feat/csv-sort/.whiska-brief.md"]))
    assert brief =~ "# Whiska: build mouse"
    assert brief =~ "sortable by date"

    assert_received {:prompt, prompt}
    refute prompt =~ "sortable by date"

    mouse = mouse_on(ctx.repo, "feat/csv-sort")
    assert %{mode: "build", model: "opus", pane: "w9:p1", base: "main"} = mouse
    assert mouse.shaped_at
  end

  test "a branch name outside a-z, 0-9, - and / is refused before herdr is asked", ctx do
    assert {1, _out, err} = spawn_mouse(["build", "Feat/CSV", ctx.task], ctx.repo)
    assert err =~ "Feat/CSV"
  end

  test "a branch that already exists is refused before herdr is asked", ctx do
    GitRepo.git!(ctx.repo.checkout, ["branch", "feat/taken"])

    assert {1, _out, err} = spawn_mouse(["build", "feat/taken", ctx.task], ctx.repo)
    assert err =~ "feat/taken"
  end

  test "--from hands a fresh mouse the question by its id and the comments as a file", ctx do
    {id, _} = finished_investigation(ctx.repo)
    comments = Path.join(ctx.root, "comments.md")
    File.write!(comments, "1. Keep the old flag.\n")
    herdr_creates(ctx.repo, "feat/from-research")
    expect(Herdr, :start_agent, fn @socket, "w9:p1", _name, args -> {:ok, args} end)

    expect(Herdr, :prompt, fn @socket, "w9:p1", text ->
      send(self(), {:prompt, text})
      :ok
    end)

    assert {0, _out, _err} =
             spawn_mouse(
               ["build", "feat/from-research", "--from", id, "--comments", comments],
               ctx.repo
             )

    worktree = Path.join(ctx.repo.checkout, "worktrees/feat/from-research")
    brief = File.read!(Path.join(worktree, ".whiska-brief.md"))
    assert brief =~ "whiska show #{id}"
    refute brief =~ "Keep the old flag"
    refute brief =~ "do the thing"

    [copied] = Path.wildcard(Path.join(worktree, ".whiska-letters/*"))
    assert brief =~ copied
    assert File.read!(copied) =~ "Keep the old flag"

    assert_received {:prompt, prompt}
    refute prompt =~ "Keep the old flag"
    refute prompt =~ "do the thing"
  end

  test "--from names a question this house has", ctx do
    assert {1, _out, err} = spawn_mouse(["build", "feat/x", "--from", "999"], ctx.repo)
    assert err =~ "999"
  end

  defp finished_investigation(repo) do
    Storage.within(repo.checkout, fn ->
      {:ok, _} = Storage.record_mouse(%{mouse_id: "sniff1", path: "/gone", branch: "research/a"})

      {:ok, q} =
        Storage.record_question(%{
          mouse_id: "sniff1",
          text: "Found it.\n\n**What to change**\n- Build: do the thing.",
          kind: "done",
          status: "open"
        })

      {to_string(q.id), q}
    end)
  end
end
