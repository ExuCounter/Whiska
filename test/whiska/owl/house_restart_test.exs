defmodule Whiska.Owl.HouseRestartTest do
  @moduledoc """
  The house restarting a mouse herdr restored without its launch flags
  (ADR-0044, ADR-0069, ADR-0090).
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
    root = Path.join(System.tmp_dir!(), "whiska-hr-#{Whiska.Test.Unique.id()}")
    File.mkdir_p!(root)
    repo = GitRepo.create(root)
    path = GitRepo.worktree(repo, "feat-a")
    File.write!(Path.join(path, ".whiska-brief.md"), "brief")
    File.write!(Path.join(path, ".whiska-settings.json"), "{}")

    {:ok, handle} = Storage.open(repo.checkout, name: nil)
    {:ok, _} = Storage.record_mouse(%{mouse_id: "ma", path: path, branch: "feat-a"})
    {:ok, _} = Storage.shape("ma", "build", "sonnet", "medium")
    Storage.close(handle)

    stub(Herdr, :subscribe, fn @socket, _subs, _listener -> {:ok, spawn(fn -> :ok end)} end)

    stub(Herdr, :worktrees, fn @socket, _checkout ->
      {:ok, [%{path: path, branch: "feat-a", workspace_id: "ws-1"}]}
    end)

    stub(Herdr, :read_screen, fn _, _ -> {:ok, "────\n❯\u00a0\n────\n"} end)

    stub(Herdr, :list_panes, fn @socket ->
      {:ok,
       [
         %{
           pane_id: "w1:p1",
           cwd: path,
           agent: "claude",
           agent_status: "idle",
           title: nil,
           session: "s-1"
         }
       ]}
    end)

    stub(Herdr, :processes, fn @socket, "w1:p1" ->
      {:ok, [%{name: "claude", argv: ["claude", "--resume", "s-1"]}]}
    end)

    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, repo: repo, path: path}
  end

  defp open(repo, opts) do
    name = :"house-#{System.unique_integer([:positive])}"
    allow(Herdr, self(), fn -> Process.whereis(name) end)

    pid =
      start_supervised!(
        {House,
         [
           name: name,
           main_checkout: repo.checkout,
           herdr_socket: @socket,
           board_ms: 60_000,
           backstop_ms: 20
         ] ++ opts}
      )

    House.sync(pid)
    pid
  end

  defp stub_exit(test_pid) do
    exited = :counters.new(1, [])
    {:ok, [live]} = Herdr.list_panes(@socket)

    stub(Herdr, :prompt, fn @socket, "w1:p1", "/exit" ->
      :counters.put(exited, 1, 1)
      send(test_pid, :exited)
      :ok
    end)

    stub(Herdr, :pane, fn @socket, "w1:p1" ->
      if :counters.get(exited, 1) == 1, do: {:ok, %{live | agent: nil}}, else: {:ok, live}
    end)
  end

  test "a restored mouse is exited and started again with every flag, once", %{repo: repo} do
    test_pid = self()

    stub_exit(test_pid)

    stub(Herdr, :start_agent, fn @socket, "w1:p1", "feat-a", args ->
      send(test_pid, {:started, args})
      {:ok, []}
    end)

    log =
      capture_io(:stderr, fn ->
        house = open(repo, [])
        assert_receive {:started, args}, 5_000
        assert ["--resume", "s-1", "--model", "sonnet" | _] = args
        assert "--dangerously-skip-permissions" in args
        Process.sleep(150)
        House.sync(house)
      end)

    assert log =~ "feat-a"
    assert log =~ "restarted"
    assert_received :exited
    refute_received :exited
    refute_received {:started, _}
  end

  test "a restart herdr refuses is told once and not tried again", %{repo: repo} do
    test_pid = self()
    stub_exit(test_pid)
    stub(Herdr, :start_agent, fn _, _, _, _ -> {:error, :boom} end)
    stub(Herdr, :notify, fn @socket, hoot -> send(test_pid, {:hoot, hoot}) && {:ok, :shown} end)

    capture_io(:stderr, fn ->
      house = open(repo, [])
      assert_receive {:hoot, hoot}, 5_000
      assert hoot.title =~ "feat-a"
      assert hoot.title =~ "launch flags"
      Process.sleep(150)
      House.sync(house)
    end)

    assert_received :exited
    refute_received :exited
    refute_received {:hoot, _}
  end

  test "a mouse seen with its flags is forgotten, so a second herdr restart is repaired", %{
    repo: repo
  } do
    test_pid = self()
    exited = :counters.new(1, [])
    calls = :counters.new(1, [])
    {:ok, [live]} = Herdr.list_panes(@socket)

    flags = [
      "claude",
      "--dangerously-skip-permissions",
      "--append-system-prompt-file",
      ".whiska-brief.md"
    ]

    stub(Herdr, :processes, fn @socket, "w1:p1" ->
      :counters.add(calls, 1, 1)
      n = :counters.get(calls, 1)
      argv = if n == 3, do: flags, else: ["claude", "--resume", "s-1"]
      {:ok, [%{name: "claude", argv: argv}]}
    end)

    stub(Herdr, :prompt, fn @socket, "w1:p1", "/exit" -> :counters.put(exited, 1, 1) && :ok end)

    stub(Herdr, :pane, fn @socket, "w1:p1" ->
      if :counters.get(exited, 1) == 1, do: {:ok, %{live | agent: nil}}, else: {:ok, live}
    end)

    stub(Herdr, :start_agent, fn @socket, "w1:p1", "feat-a", _args ->
      :counters.put(exited, 1, 0)
      send(test_pid, :started)
      {:ok, []}
    end)

    capture_io(:stderr, fn ->
      open(repo, [])
      assert_receive :started, 5_000
      assert_receive :started, 5_000
    end)
  end
end
