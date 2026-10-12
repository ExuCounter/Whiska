defmodule Whiska.Owl.HouseCleanupTest do
  @moduledoc """
  The house taking a landed worktree down on its backstop (ADR-0061).

  A real git repo, because the preconditions are git's answers and nothing
  else's, and herdr faked at its one boundary (ADR-0031).
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO
  import Mox

  alias Whiska.Herdr.Mock, as: Herdr
  alias Whiska.Owl.House
  alias Whiska.Storage
  alias Whiska.Test.GitRepo

  setup :verify_on_exit!
  setup {Whiska.Test.QuietSidebar, :stub_sidebar}

  @socket "/fake/herdr.sock"

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-hc-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    repo = GitRepo.create(root)
    path = GitRepo.worktree(repo, "feat-a")

    {:ok, handle} = Storage.open(repo.checkout, name: nil)
    {:ok, _} = Storage.record_mouse(%{mouse_id: "ma", path: path, branch: "feat-a"})

    {:ok, _} =
      Storage.record_question(%{mouse_id: "ma", text: "done", kind: "done", status: "closed"})

    Storage.close(handle)

    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, repo: repo, path: path}
  end

  # The house calls herdr from its own process, from `init/1` on, so it is
  # allowed in by name before it starts — which is what lets this file run async.
  defp start_house(opts) do
    name = :"house-#{System.unique_integer([:positive])}"
    allow(Herdr, self(), fn -> Process.whereis(name) end)
    start_supervised!({House, [name: name] ++ opts})
  end

  # The backstop sweeps on a real timer, and a loaded parallel run makes it late.
  defp until_gone(path, tries) do
    if File.dir?(path) and tries > 0 do
      Process.sleep(10)
      until_gone(path, tries - 1)
    end
  end

  defp until_fetch(house, reached, tries \\ 1000) do
    cond do
      reached.(:sys.get_state(house)) ->
        :ok

      tries > 0 ->
        Process.sleep(10)
        until_fetch(house, reached, tries - 1)

      true ->
        flunk("the house's fetch never got there")
    end
  end

  defp open(repo, opts) do
    opts = Keyword.merge([main_checkout: repo.checkout, herdr_socket: @socket], opts)
    pid = start_house(opts)
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
        until_gone(path, 500)
        House.sync(house)
      end)

    refute File.dir?(path)
    assert log =~ "feat-a"

    {:ok, handle} = Storage.open(repo.checkout, name: nil)
    assert %{removed_at: %DateTime{}} = Storage.mouse("ma")
    Storage.close(handle)
  end

  test "a landed worktree holding its mouse marker is taken down, with no gitignore to hide it",
       %{repo: repo, path: path} do
    {:ok, _} = Whiska.Marker.read_or_mint(path)
    GitRepo.land(repo, "feat-a")
    stub(Herdr, :list_panes, fn @socket -> {:ok, []} end)
    stub(Herdr, :subscribe, fn @socket, _subs, _listener -> {:ok, spawn(fn -> :ok end)} end)

    stub(Herdr, :worktrees, fn @socket, _checkout ->
      {:ok, [%{path: path, branch: "feat-a", workspace_id: nil}]}
    end)

    capture_io(:stderr, fn ->
      house = open(repo, backstop_ms: 20, board_ms: 60_000)
      until_gone(path, 500)
      House.sync(house)
    end)

    refute File.dir?(path)
  end

  test "opening a house hides the worktrees folder from the main checkout", %{repo: repo} do
    File.mkdir_p!(Path.join([repo.checkout, "worktrees", "feat-b"]))
    File.write!(Path.join([repo.checkout, "worktrees", "feat-b", "notes.md"]), "x")
    stub(Herdr, :list_panes, fn @socket -> {:ok, []} end)
    stub(Herdr, :subscribe, fn @socket, _subs, _listener -> {:ok, spawn(fn -> :ok end)} end)
    stub(Herdr, :worktrees, fn @socket, _checkout -> {:ok, []} end)

    capture_io(:stderr, fn -> open(repo, backstop_ms: 60_000, board_ms: 60_000) end)

    assert GitRepo.git!(repo.checkout, ["status", "--porcelain"]) == ""
  end

  defp record_merge_request(repo) do
    {:ok, handle} = Storage.open(repo.checkout, name: nil)
    {:ok, _} = Storage.record_merge_request("ma", "https://github.com/o/r/pull/1")
    Storage.close(handle)
  end

  defp quiet_herdr(path) do
    stub(Herdr, :list_panes, fn @socket -> {:ok, []} end)
    stub(Herdr, :subscribe, fn @socket, _subs, _listener -> {:ok, spawn(fn -> :ok end)} end)

    stub(Herdr, :worktrees, fn @socket, _checkout ->
      {:ok, [%{path: path, branch: "feat-a", workspace_id: nil}]}
    end)
  end

  test "a merge request merged on the forge is fetched, and its worktree taken down",
       %{repo: repo, path: path} do
    record_merge_request(repo)
    GitRepo.merge_on_forge(repo, "feat-a")
    local = GitRepo.git!(repo.checkout, ["rev-parse", "main"])
    quiet_herdr(path)

    capture_io(:stderr, fn ->
      house = open(repo, backstop_ms: 20, board_ms: 60_000)
      until_gone(path, 500)
      House.sync(house)
    end)

    refute File.dir?(path)
    assert GitRepo.git!(repo.checkout, ["rev-parse", "main"]) == local
  end

  test "with no merge request waiting, the base is never fetched", %{repo: repo, path: path} do
    GitRepo.merge_on_forge(repo, "feat-a")
    fetched = GitRepo.git!(repo.checkout, ["rev-parse", "origin/main"])
    quiet_herdr(path)

    capture_io(:stderr, fn ->
      house = open(repo, backstop_ms: 20, board_ms: 60_000)
      Process.sleep(200)
      House.sync(house)
    end)

    assert File.dir?(path)
    assert GitRepo.git!(repo.checkout, ["rev-parse", "origin/main"]) == fetched
  end

  test "a fetch that keeps failing is said once", %{repo: repo, path: path} do
    record_merge_request(repo)
    GitRepo.git!(repo.checkout, ["remote", "set-url", "origin", Path.join(repo.root, "gone")])
    quiet_herdr(path)

    log =
      capture_io(:stderr, fn ->
        house = open(repo, backstop_ms: 20, board_ms: 60_000, fetch_ms: 10)
        until_fetch(house, &((&1.fetch_wait_ms || 0) >= 80))
      end)

    assert [_once] = Regex.scan(~r/fetching main/, log)
    assert File.dir?(path)
  end

  test "a fetch failing for a later merge request is said again",
       %{repo: repo, path: path} do
    record_merge_request(repo)
    GitRepo.git!(repo.checkout, ["remote", "set-url", "origin", Path.join(repo.root, "gone")])
    later = GitRepo.worktree(repo, "feat-b", push: false)
    quiet_herdr(path)

    log =
      capture_io(:stderr, fn ->
        house = open(repo, backstop_ms: 20, board_ms: 60_000, fetch_ms: 200, fetch_max_ms: 60_000)
        until_fetch(house, & &1.fetch_failing)

        {:ok, handle} = Storage.open(repo.checkout, name: nil)
        {:ok, _} = Storage.mark_removed("ma")
        until_fetch(house, &(not &1.fetch_failing))
        {:ok, _} = Storage.record_mouse(%{mouse_id: "mb", path: later, branch: "feat-b"})
        {:ok, _} = Storage.record_merge_request("mb", "https://github.com/o/r/pull/2")
        Storage.close(handle)

        until_fetch(house, & &1.fetch_failing)
      end)

    assert [_first, _again] = Regex.scan(~r/fetching main/, log)
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
