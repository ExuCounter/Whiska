defmodule Whiska.SendTest do
  @moduledoc """
  `whiska send` through the CLI, over a real git repo and a fake herdr
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
    root = Path.join(System.tmp_dir!(), "whiska-send-#{System.unique_integer([:positive])}")
    repo = GitRepo.create(root)
    path = GitRepo.worktree(repo, "feat-a")
    note = Path.join(root, "note.md")
    File.write!(note, "Also keep the old flag working.\n")

    Storage.within(repo.checkout, fn ->
      {:ok, _} =
        Storage.record_mouse(%{mouse_id: "m1", path: path, branch: "feat-a", pane: "w2:p3"})
    end)

    was = System.get_env("HERDR_SOCKET_PATH")
    System.put_env("HERDR_SOCKET_PATH", @socket)

    on_exit(fn ->
      if was,
        do: System.put_env("HERDR_SOCKET_PATH", was),
        else: System.delete_env("HERDR_SOCKET_PATH")

      File.rm_rf!(root)
    end)

    {:ok, repo: repo, path: path, note: note}
  end

  defp send_note(args, repo) do
    parent = self()

    err =
      capture_io(:stderr, fn ->
        out = capture_io(fn -> send(parent, {:code, CLI.run(["send" | args], repo.checkout)}) end)
        send(parent, {:out, out})
      end)

    assert_received {:code, code}
    assert_received {:out, out}
    {code, out, err}
  end

  test "the words land in the mouse's worktree, and one fixed line points it there", ctx do
    expect(Herdr, :pane, fn @socket, "w2:p3" ->
      {:ok, %{pane_id: "w2:p3", agent_status: "working"}}
    end)

    expect(Herdr, :prompt, fn @socket, "w2:p3", line ->
      send(self(), {:line, line})
      :ok
    end)

    assert {0, out, _} = send_note(["feat-a", ctx.note], ctx.repo)
    assert out =~ "feat-a"
    assert out =~ "after"

    assert_received {:line, line}
    refute line =~ "old flag"
    [copy] = Path.wildcard(Path.join(ctx.path, ".whiska-inbox/*.md"))
    assert line =~ copy
    assert File.read!(copy) == File.read!(ctx.note)
    assert GitRepo.git!(ctx.path, ["status", "--porcelain"]) == ""
  end

  test "a branch with no live mouse on it is refused, and nothing is copied", ctx do
    assert {1, _, err} = send_note(["feat-nobody", ctx.note], ctx.repo)
    assert err =~ "feat-nobody"
    assert Path.wildcard(Path.join(ctx.path, ".whiska-inbox/*")) == []
  end
end
