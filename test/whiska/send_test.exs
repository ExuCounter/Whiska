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
  alias Whiska.Delivery.Mode
  alias Whiska.Herdr.Mock, as: Herdr
  alias Whiska.Storage
  alias Whiska.Test.GitRepo

  setup :verify_on_exit!

  @socket "/fake/herdr.sock"

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-send-#{Whiska.Test.Unique.id()}")
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
    refute line =~ "ask it again"
    [copy] = Path.wildcard(Path.join(ctx.path, ".whiska-letters/*.md"))
    assert line =~ copy
    assert File.read!(copy) == File.read!(ctx.note)
    assert GitRepo.git!(ctx.path, ["status", "--porcelain"]) == ""
  end

  defp ask(mouse_id, text) do
    {:ok, q} =
      Storage.record_question(%{mouse_id: mouse_id, text: text, kind: "needs-decision"})

    q
  end

  defp waiting_on_feat_a(repo) do
    Storage.within(repo.checkout, fn ->
      {:ok, _} =
        Storage.record_mouse(%{mouse_id: "m2", path: "/w/b", branch: "feat-b", pane: "w3:p1"})

      asked = ask("m1", "Which way?")
      {:ok, _} = Storage.mark_sent(asked.id)
      {asked, ask("m2", "Ready to land?")}
    end)
  end

  test "a letter retires the question its mouse was waiting on, and frees the slot", ctx do
    {asked, other} = waiting_on_feat_a(ctx.repo)

    expect(Herdr, :pane, fn @socket, "w2:p3" ->
      {:ok, %{pane_id: "w2:p3", agent_status: "idle"}}
    end)

    expect(Herdr, :prompt, fn @socket, "w2:p3", line ->
      send(self(), {:line, line})
      :ok
    end)

    assert {0, out, _} = send_note(["feat-a", ctx.note], ctx.repo)
    assert out =~ "##{asked.id} no longer waits on you"

    assert_received {:line, line}
    assert line =~ "ask it again"

    Storage.within(ctx.repo.checkout, fn ->
      assert Storage.question(asked.id).status == "superseded"
      assert Mode.next(Storage.questions(), Mode.none()).id == other.id
    end)
  end

  test "a letter retires a finished line still queued too, and names each", ctx do
    {asked, _other} = waiting_on_feat_a(ctx.repo)

    finished =
      Storage.within(ctx.repo.checkout, fn ->
        {:ok, q} =
          Storage.record_question(%{mouse_id: "m1", text: "## Summary\nDone.", kind: "done"})

        q
      end)

    expect(Herdr, :pane, fn @socket, "w2:p3" ->
      {:ok, %{pane_id: "w2:p3", agent_status: "idle"}}
    end)

    expect(Herdr, :prompt, fn @socket, "w2:p3", _line -> :ok end)

    assert {0, out, _} = send_note(["feat-a", ctx.note], ctx.repo)
    assert out =~ "##{asked.id}, ##{finished.id} no longer wait on you"

    Storage.within(ctx.repo.checkout, fn ->
      assert Storage.question(finished.id).status == "superseded"
    end)
  end

  test "a pane that refuses the line retires nothing", ctx do
    {asked, _other} = waiting_on_feat_a(ctx.repo)

    expect(Herdr, :pane, fn @socket, "w2:p3" ->
      {:ok, %{pane_id: "w2:p3", agent_status: "idle"}}
    end)

    expect(Herdr, :prompt, fn @socket, "w2:p3", _line -> {:error, :closed} end)

    assert {1, _, _} = send_note(["feat-a", ctx.note], ctx.repo)

    Storage.within(ctx.repo.checkout, fn ->
      assert Storage.question(asked.id).status == "sent"
    end)
  end

  test "a branch with no live mouse on it is refused, and nothing is copied", ctx do
    assert {1, _, err} = send_note(["feat-nobody", ctx.note], ctx.repo)
    assert err =~ "feat-nobody"
    assert Path.wildcard(Path.join(ctx.path, ".whiska-letters/*")) == []
  end
end
