defmodule Whiska.Owl.HouseCleanupTest do
  @moduledoc """
  The house taking a landed worktree down on its backstop (ADR-0061).

  A real git repo, because the preconditions are git's answers and nothing
  else's, and herdr faked at its one boundary (ADR-0031).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import Mox

  alias Whiska.Herdr.Mock, as: Herdr
  alias Whiska.Owl.House
  alias Whiska.Storage
  alias Whiska.Test.GitRepo

  setup :set_mox_global
  setup :verify_on_exit!

  @socket "/fake/herdr.sock"

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-hc-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    repo = GitRepo.create(root)
    path = GitRepo.worktree(repo, "feat-a")

    {:ok, handle} = Storage.open(repo.checkout, name: :seed)
    {:ok, _} = Storage.record_mouse(%{mouse_id: "ma", path: path, branch: "feat-a"})

    {:ok, _} =
      Storage.record_question(%{mouse_id: "ma", text: "done", kind: "done", status: "closed"})

    Storage.close(handle)

    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, repo: repo, path: path}
  end

  defp open(repo, opts) do
    opts = Keyword.merge([main_checkout: repo.checkout, herdr_socket: @socket], opts)
    pid = start_supervised!({House, opts})
    House.sync(pid)
    pid
  end

  test "the backstop takes down a landed worktree and says so", %{repo: repo, path: path} do
    GitRepo.land(repo, "feat-a")
    stub(Herdr, :list_panes, fn @socket -> {:ok, []} end)
    stub(Herdr, :subscribe, fn @socket, _subs, _listener -> {:ok, spawn(fn -> :ok end)} end)

    stub(Herdr, :worktrees, fn @socket, _checkout ->
      {:ok, [%{path: path, branch: "feat-a", workspace_id: nil}]}
    end)

    log =
      capture_io(:stderr, fn ->
        house = open(repo, backstop_ms: 20, board_ms: 60_000)
        Process.sleep(200)
        House.sync(house)
      end)

    refute File.dir?(path)
    assert log =~ "feat-a"

    {:ok, handle} = Storage.open(repo.checkout, name: :check)
    assert %{removed_at: %DateTime{}} = Storage.mouse("ma")
    Storage.close(handle)
  end

  test "a worktree still being worked in is left exactly where it is", %{repo: repo, path: path} do
    stub(Herdr, :list_panes, fn @socket -> {:ok, []} end)
    stub(Herdr, :subscribe, fn @socket, _subs, _listener -> {:ok, spawn(fn -> :ok end)} end)
    stub(Herdr, :worktrees, fn @socket, _checkout -> {:ok, []} end)

    capture_io(:stderr, fn ->
      house = open(repo, backstop_ms: 20, board_ms: 60_000)
      Process.sleep(200)
      House.sync(house)
    end)

    assert File.dir?(path)
  end
end
