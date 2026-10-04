defmodule Whiska.CLIWorktreesTest do
  @moduledoc """
  `whiska worktrees`, with herdr faked at the boundary ADR-0031 names.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import Mox

  alias Whiska.CLI
  alias Whiska.Herdr.Mock, as: Herdr

  setup :verify_on_exit!

  setup do
    was_socket = System.get_env("HERDR_SOCKET_PATH")
    System.put_env("HERDR_SOCKET_PATH", "/tmp/whiska-test-herdr.sock")

    on_exit(fn ->
      if was_socket,
        do: System.put_env("HERDR_SOCKET_PATH", was_socket),
        else: System.delete_env("HERDR_SOCKET_PATH")
    end)
  end

  defp pane(id, workspace, status) do
    %{
      pane_id: id,
      workspace_id: workspace,
      cwd: nil,
      agent: "claude",
      agent_status: status,
      title: nil,
      session: nil,
      scroll_offset: 0
    }
  end

  test "prints one tab-separated line per linked worktree: branch, path, workspace, pane, status" do
    expect(Herdr, :worktrees, fn _, "/main" ->
      {:ok,
       [
         %{path: "/main/worktrees/feat-a", branch: "feat-a", workspace_id: "w7"},
         %{path: "/main/worktrees/feat-b", branch: "feat-b", workspace_id: "w8"}
       ]}
    end)

    expect(Herdr, :list_panes, fn _ ->
      {:ok, [pane("w8:p1", "w8", "idle"), pane("w7:p1", "w7", "working")]}
    end)

    out = capture_io(fn -> assert CLI.run(["worktrees"], "/main") == 0 end)

    assert out ==
             "feat-a\t/main/worktrees/feat-a\tw7\tw7:p1\tworking\n" <>
               "feat-b\t/main/worktrees/feat-b\tw8\tw8:p1\tidle\n"
  end

  test "a worktree with no workspace open has dashes where the workspace and pane would be" do
    expect(Herdr, :worktrees, fn _, _ ->
      {:ok, [%{path: "/main/worktrees/old", branch: "old", workspace_id: nil}]}
    end)

    expect(Herdr, :list_panes, fn _ -> {:ok, []} end)

    out = capture_io(fn -> assert CLI.run(["worktrees"], "/main") == 0 end)
    assert out == "old\t/main/worktrees/old\t-\t-\t-\n"
  end

  test "says so, and exits 0, when there are no linked worktrees" do
    expect(Herdr, :worktrees, fn _, _ -> {:ok, []} end)
    expect(Herdr, :list_panes, fn _ -> {:ok, []} end)

    out = capture_io(fn -> assert CLI.run(["worktrees"], "/main") == 0 end)
    assert out =~ "No linked worktrees"
  end

  test "a herdr that refuses is an error on stderr and exit 1" do
    expect(Herdr, :worktrees, fn _, _ ->
      {:error, {:herdr, %{"code" => "boom", "message" => "no"}}}
    end)

    err = capture_io(:stderr, fn -> assert CLI.run(["worktrees"], "/main") == 1 end)
    assert err =~ "boom: no"
  end
end
