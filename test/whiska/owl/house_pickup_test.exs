defmodule Whiska.Owl.HousePickupTest do
  @moduledoc """
  The house picking a died turn up on its backstop (ADR-0065).

  A real house with herdr faked at its one boundary (ADR-0031). The settling
  window is wound right down so a test can watch two sweeps go past without
  waiting two minutes.
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
    root = Path.join(System.tmp_dir!(), "whiska-hp-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    repo = GitRepo.create(root)
    path = GitRepo.worktree(repo, "feat-a")

    {:ok, handle} = Storage.open(repo.checkout, name: :seed)
    {:ok, _} = Storage.record_mouse(%{mouse_id: "ma", path: path, branch: "feat-a"})
    Storage.close(handle)

    stub(Herdr, :subscribe, fn @socket, _subs, _listener -> {:ok, spawn(fn -> :ok end)} end)

    stub(Herdr, :worktrees, fn @socket, _checkout ->
      {:ok, [%{path: path, branch: "feat-a", workspace_id: "ws-1"}]}
    end)

    stub(Herdr, :read_screen, fn _, _ -> {:error, :no_screen} end)
    stub(Herdr, :pane, fn _, _ -> {:error, :no_pane} end)

    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, repo: repo, path: path}
  end

  defp pane(path, status) do
    %{
      pane_id: "w1:p1",
      cwd: path,
      agent: "claude",
      agent_status: status,
      title: nil,
      session: nil
    }
  end

  defp open(repo, opts) do
    opts =
      Keyword.merge(
        [
          main_checkout: repo.checkout,
          herdr_socket: @socket,
          board_ms: 60_000,
          settle_ms: 1,
          max_gap_ms: 5_000
        ],
        opts
      )

    pid = start_supervised!({House, opts})
    House.sync(pid)
    pid
  end

  defp check(repo, fun) do
    {:ok, handle} = Storage.open(repo.checkout, name: :check)

    try do
      fun.()
    after
      Storage.close(handle)
    end
  end

  test "a pane that worked and went quiet with nothing collected is picked up",
       %{repo: repo, path: path} do
    stub(Herdr, :list_panes, fn @socket -> {:ok, [pane(path, "done")]} end)

    test_pid = self()

    stub(Herdr, :prompt, fn @socket, "w1:p1", line ->
      send(test_pid, {:typed, line})
      :ok
    end)

    log =
      capture_io(:stderr, fn ->
        house = open(repo, backstop_ms: 20)

        send(
          house,
          {:herdr_event, "pane.agent_status_changed",
           %{"pane_id" => "w1:p1", "agent_status" => "working"}}
        )

        House.sync(house)
        Process.sleep(300)
        House.sync(house)
      end)

    assert_receive {:typed, line}, 1_000
    assert line == Whiska.Pickup.line()
    assert log =~ "feat-a"
    assert log =~ "picked it up"

    check(repo, fn -> assert %{picked_up_at: %DateTime{}} = Storage.mouse("ma") end)
  end

  test "a pane that never stopped working is left alone", %{repo: repo, path: path} do
    stub(Herdr, :list_panes, fn @socket -> {:ok, [pane(path, "working")]} end)

    capture_io(:stderr, fn ->
      house = open(repo, backstop_ms: 20)
      Process.sleep(200)
      House.sync(house)
    end)

    check(repo, fn -> assert Storage.mouse("ma").picked_up_at == nil end)
  end

  test "a working report over the subscription is what says a turn began",
       %{repo: repo, path: path} do
    stub(Herdr, :list_panes, fn @socket -> {:ok, [pane(path, "done")]} end)

    capture_io(:stderr, fn ->
      house = open(repo, backstop_ms: 60_000)

      send(
        house,
        {:herdr_event, "pane.agent_status_changed",
         %{"pane_id" => "w1:p1", "agent_status" => "working"}}
      )

      House.sync(house)
    end)

    check(repo, fn -> assert %DateTime{} = Storage.mouse("ma").worked_at end)
  end

  test "herdr dropping the subscription starts every settling clock again",
       %{repo: repo, path: path} do
    stub(Herdr, :list_panes, fn @socket -> {:ok, [pane(path, "done")]} end)

    capture_io(:stderr, fn ->
      house = open(repo, backstop_ms: 60_000)
      House.sync(house)
      assert House.seen(house) != %{}
      send(house, {:herdr_subscription_lost, :closed})
      House.sync(house)
      assert House.seen(house) == %{}
    end)
  end
end
