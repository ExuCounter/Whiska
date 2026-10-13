defmodule Whiska.PRTest do
  @moduledoc """
  `whiska pr` through the CLI, over a real git repo and its bare remote, with a
  fake `gh` on PATH.
  """
  # Serial: the house opens under the one VM-wide name `Whiska.Repo`, and the
  # test puts a fake `gh` first on the OS PATH.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Whiska.CLI
  alias Whiska.Storage
  alias Whiska.Test.GitRepo

  @message "The CSV page sorts by date.\n\n- Changed: the date column sorts.\n"

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-pr-#{System.unique_integer([:positive])}")
    repo = GitRepo.create(root)
    path = GitRepo.worktree(repo, "feat-a", push: false)
    calls = Path.join(root, "gh-calls")
    bin = Path.join(root, "bin")
    File.mkdir_p!(bin)

    File.write!(Path.join(bin, "gh"), """
    #!/bin/sh
    printf '%s\\n' "$@" >> '#{calls}'
    while [ $# -gt 0 ]; do
      if [ "$1" = "--body-file" ]; then cp "$2" '#{calls}.body'; fi
      shift
    done
    echo "https://github.com/acme/app/pull/7"
    """)

    File.chmod!(Path.join(bin, "gh"), 0o755)
    was = System.get_env("PATH")
    System.put_env("PATH", bin <> ":" <> was)

    id =
      Storage.within(repo.checkout, fn ->
        {:ok, _} = Storage.record_mouse(%{mouse_id: "m1", path: path, branch: "feat-a"})

        {:ok, q} =
          Storage.record_question(%{mouse_id: "m1", text: @message, kind: "done", status: "open"})

        to_string(q.id)
      end)

    on_exit(fn ->
      System.put_env("PATH", was)
      File.rm_rf!(root)
    end)

    {:ok, repo: repo, path: path, id: id, calls: calls}
  end

  defp pr(args, repo) do
    parent = self()

    err =
      capture_io(:stderr, fn ->
        out = capture_io(fn -> send(parent, {:code, CLI.run(["pr" | args], repo.checkout)}) end)
        send(parent, {:out, out})
      end)

    assert_received {:code, code}
    assert_received {:out, out}
    {code, out, err}
  end

  defp on_remote(repo, branch),
    do: GitRepo.git!(repo.remote, ["rev-parse", "--verify", "--quiet", "refs/heads/#{branch}"])

  test "pushes the branch by name, opens it with the mouse's message, and records the link",
       ctx do
    assert {0, out, _} = pr([ctx.id], ctx.repo)
    assert out =~ "https://github.com/acme/app/pull/7"

    assert on_remote(ctx.repo, "feat-a") == GitRepo.git!(ctx.path, ["rev-parse", "HEAD"])
    args = File.read!(ctx.calls) |> String.split("\n", trim: true)
    assert ["pr", "create" | _] = args
    assert Enum.chunk_every(args, 2, 1) |> Enum.member?(["--head", "feat-a"])
    assert Enum.chunk_every(args, 2, 1) |> Enum.member?(["--base", "main"])
    assert Enum.chunk_every(args, 2, 1) |> Enum.member?(["--title", "add feat-a.md"])
    assert File.read!(ctx.calls <> ".body") == @message

    Storage.within(ctx.repo.checkout, fn ->
      assert %{merge_request_url: "https://github.com/acme/app/pull/7"} = Storage.mouse("m1")
    end)
  end

  test "a branch whose merge request is open gets its new commits pushed, and none is opened",
       ctx do
    assert {0, _, _} = pr([ctx.id], ctx.repo)
    File.rm!(ctx.calls)
    GitRepo.commit!(ctx.path, "more.md", "more")

    assert {0, out, _} = pr([ctx.id], ctx.repo)
    assert out =~ "https://github.com/acme/app/pull/7"
    assert on_remote(ctx.repo, "feat-a") == GitRepo.git!(ctx.path, ["rev-parse", "HEAD"])
    refute File.exists?(ctx.calls)
  end
end
