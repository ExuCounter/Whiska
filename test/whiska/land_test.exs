defmodule Whiska.LandTest do
  @moduledoc """
  `whiska land` through the CLI, over a real git repo.
  """
  # Serial: the house opens under the one VM-wide name `Whiska.Repo`.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Whiska.CLI
  alias Whiska.Storage
  alias Whiska.Test.GitRepo

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-land-#{System.unique_integer([:positive])}")
    repo = GitRepo.create(root)
    path = GitRepo.worktree(repo, "feat-a")
    GitRepo.commit!(path, "second.md", "more")
    ran = Path.join(root, "checks-ran")

    File.write!(Path.join(repo.checkout, "CLAUDE.md"), """
    # Repo

    ## Finish

    checks: touch #{ran}, true
    """)

    GitRepo.git!(repo.checkout, ["add", "CLAUDE.md"])
    GitRepo.git!(repo.checkout, ["commit", "-m", "add CLAUDE.md"])

    id =
      Storage.within(repo.checkout, fn ->
        {:ok, _} = Storage.record_mouse(%{mouse_id: "m1", path: path, branch: "feat-a"})

        {:ok, q} =
          Storage.record_question(%{mouse_id: "m1", text: "Done.", kind: "done", status: "open"})

        to_string(q.id)
      end)

    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, repo: repo, root: root, path: path, id: id, ran: ran}
  end

  defp land(args, repo) do
    parent = self()

    err =
      capture_io(:stderr, fn ->
        out = capture_io(fn -> send(parent, {:code, CLI.run(["land" | args], repo.checkout)}) end)
        send(parent, {:out, out})
      end)

    assert_received {:code, code}
    assert_received {:out, out}
    {code, out, err}
  end

  defp subjects(repo),
    do:
      GitRepo.git!(repo.checkout, ["log", "--format=%s", "main"])
      |> String.split("\n", trim: true)

  test "copies the branch's commits onto the checkout, oldest first, then runs the repo's checks",
       ctx do
    assert {0, out, _} = land([ctx.id], ctx.repo)
    assert out =~ "feat-a"
    assert ["add second.md", "add feat-a.md", "add CLAUDE.md" | _] = subjects(ctx.repo)
    assert File.exists?(ctx.ran)
    assert File.dir?(ctx.path)
  end

  test "files the mouse left uncommitted are named, and land only with --commit", ctx do
    GitRepo.dirty!(ctx.path)

    assert {1, _, err} = land([ctx.id], ctx.repo)
    assert err =~ "scratch.txt"
    assert err =~ "--commit"
    assert ["add CLAUDE.md" | _] = subjects(ctx.repo)

    message = Path.join(ctx.root, "message.txt")
    File.write!(message, "feat: keep the scratch\n")

    assert {0, _, _} = land([ctx.id, "--commit", message], ctx.repo)
    assert ["feat: keep the scratch", "add second.md" | _] = subjects(ctx.repo)
  end

  test "the hooks spawn carried in from an uncommitted install are neither named nor committed",
       ctx do
    for root <- [ctx.repo.checkout, ctx.path] do
      File.mkdir_p!(Path.join(root, ".claude/hooks"))
      File.write!(Path.join(root, ".claude/settings.json"), "{}\n")
      File.write!(Path.join(root, ".claude/hooks/whiska.sh"), "#!/bin/sh\n")
    end

    GitRepo.dirty!(ctx.path)

    assert {1, _, err} = land([ctx.id], ctx.repo)
    assert err =~ "scratch.txt"
    refute err =~ ".claude"

    message = Path.join(ctx.root, "message.txt")
    File.write!(message, "feat: keep the scratch\n")

    assert {0, _, _} = land([ctx.id, "--commit", message], ctx.repo)
    assert GitRepo.git!(ctx.repo.checkout, ["ls-files", ".claude"]) == ""
  end

  test "a failing check is named, and the copies stay for the person", ctx do
    File.write!(Path.join(ctx.repo.checkout, "CLAUDE.md"), "## Finish\n\nchecks: false\n")
    GitRepo.git!(ctx.repo.checkout, ["commit", "-am", "break the checks"])

    assert {1, _, err} = land([ctx.id], ctx.repo)
    assert err =~ "false"
    assert ["add second.md" | _] = subjects(ctx.repo)
  end

  test "a branch whose work clashes with the checkout lands nothing", ctx do
    GitRepo.commit!(ctx.repo.checkout, "second.md", "the checkout's own")

    assert {1, _, err} = land([ctx.id], ctx.repo)
    assert err =~ "second.md"
    assert ["add second.md", "add CLAUDE.md" | _] = subjects(ctx.repo)
    assert GitRepo.git!(ctx.repo.checkout, ["status", "--porcelain"]) == ""
  end
end
