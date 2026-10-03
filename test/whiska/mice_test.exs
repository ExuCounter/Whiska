defmodule Whiska.MiceTest do
  @moduledoc """
  `whiska mice`: what is alive in this house, one line per mouse.

  The rows are pure: mouse records in, herdr's pane list in, lines out. Only
  the herdr call is faked (ADR-0031); the house itself is a real SQLite file.
  """
  use ExUnit.Case, async: true

  import Mox

  alias Whiska.Herdr.Mock, as: Herdr
  alias Whiska.Mice
  alias Whiska.Schema.Mouse
  alias Whiska.Storage

  setup :verify_on_exit!

  @now ~U[2026-09-27 12:00:00Z]

  defp mouse(id, branch, opts \\ []) do
    %Mouse{
      mouse_id: id,
      branch: branch,
      path: Keyword.get(opts, :path, "/repo/worktrees/#{branch}"),
      mode: Keyword.get(opts, :mode, "build"),
      created_at: Keyword.get(opts, :created_at, @now)
    }
  end

  defp pane(id, cwd, status), do: %{pane_id: id, cwd: cwd, agent: "claude", agent_status: status}

  describe "a branch the owl picked up (ADR-0067)" do
    test "says so, and when, for as long as the mouse lives" do
      mice = [%{mouse("ma", "feat-a") | picked_up_at: DateTime.add(@now, -7200, :second)}]

      assert [%{note: "picked up 2h 0m ago"}] = Mice.rows(mice, {:ok, []}, @now)
    end

    test "a mouse nobody picked up says nothing" do
      assert [%{note: ""}] = Mice.rows([mouse("ma", "feat-a")], {:ok, []}, @now)
    end

    test "a listing with no pickup in it carries no column for one" do
      rows = Mice.rows([mouse("ma", "feat-a")], {:ok, []}, @now)

      refute Mice.render(rows) =~ "picked up"
      refute String.ends_with?(Mice.render(rows), " ")
    end
  end

  describe "rows/3" do
    test "takes a mouse's status from the herdr pane sitting in its worktree (ADR-0020)" do
      mice = [mouse("ma", "feat-a"), mouse("mb", "feat-b", mode: "sniff")]

      panes =
        {:ok,
         [
           pane("w1:p1", "/repo/worktrees/feat-a/lib", "working"),
           pane("w1:p2", "/repo/worktrees/feat-b", "idle"),
           pane("w1:p3", "/repo", "idle")
         ]}

      assert [
               %{branch: "feat-a", mode: "build", status: "working"},
               %{branch: "feat-b", mode: "sniff", status: "idle"}
             ] = Mice.rows(mice, panes, @now)
    end

    test "a mouse with no agent pane in its worktree shows 'no pane', and is not marked dead" do
      # Marking dead is the owl's job (ADR-0026); a listing only reports.
      panes =
        {:ok,
         [%{pane_id: "w1:p1", cwd: "/repo/worktrees/feat-a", agent: nil, agent_status: "unknown"}]}

      assert [%{status: "no pane"}] = Mice.rows([mouse("ma", "feat-a")], panes, @now)
    end

    test "when herdr cannot be asked, every status is '?'" do
      mice = [mouse("ma", "feat-a"), mouse("mb", "feat-b")]

      assert [%{status: "?"}, %{status: "?"}] = Mice.rows(mice, {:error, :econnrefused}, @now)
      assert [%{status: "?"}, %{status: "?"}] = Mice.rows(mice, :no_socket, @now)
    end

    test "uptime is measured from the mouse record's creation" do
      mice = [mouse("ma", "feat-a", created_at: ~U[2026-09-27 09:45:00Z])]

      assert [%{uptime: "2h 15m"}] = Mice.rows(mice, {:ok, []}, @now)
    end
  end

  describe "format_uptime/1" do
    test "reads like a person would say it" do
      assert Mice.format_uptime(0) == "0s"
      assert Mice.format_uptime(45) == "45s"
      assert Mice.format_uptime(4 * 60) == "4m"
      assert Mice.format_uptime(4 * 60 + 30) == "4m"
      assert Mice.format_uptime(2 * 3600 + 15 * 60) == "2h 15m"
      assert Mice.format_uptime(3 * 86_400 + 4 * 3600 + 59 * 60) == "3d 4h"
    end
  end

  describe "render/1" do
    test "one line per mouse, columns lined up, in the order given" do
      rows = [
        %{branch: "feat-a", mode: "build", status: "working", uptime: "2h 15m", note: ""},
        %{
          branch: "feat-longer-name",
          mode: "sniff",
          status: "no pane",
          uptime: "4m",
          note: "picked up 4m ago"
        }
      ]

      assert Mice.render(rows) ==
               """
               feat-a            build  working  2h 15m
               feat-longer-name  sniff  no pane  4m      picked up 4m ago
               """
               |> String.trim_trailing()
    end

    test "says so when nothing is alive" do
      assert Mice.render([]) == "No mice alive."
    end
  end

  describe "list/1" do
    setup do
      root = Path.join(System.tmp_dir!(), "whiska-mice-#{System.unique_integer([:positive])}")
      main = Path.join(root, "myrepo")
      File.mkdir_p!(Path.join(main, ".git"))
      on_exit(fn -> File.rm_rf!(root) end)

      {:ok, handle} = Storage.open(main, name: :seed)
      a = Path.join(main, "worktrees/feat-a")
      b = Path.join(main, "worktrees/feat-b")
      {:ok, _} = Storage.record_mouse(%{mouse_id: "ma", path: a, branch: "feat-a"})
      {:ok, _} = Storage.record_mouse(%{mouse_id: "mb", path: b, branch: "feat-b"})
      {:ok, _} = Storage.mark_dead("mb")
      Storage.close(handle)

      {:ok, main: main, a: a}
    end

    test "opens the house, asks herdr, and lists only mice that are alive", %{main: main, a: a} do
      expect(Herdr, :list_panes, fn "/fake/herdr.sock" -> {:ok, [pane("w1:p1", a, "working")]} end)

      assert {:ok, [%{branch: "feat-a", status: "working"}]} =
               Mice.list(main, herdr_socket: "/fake/herdr.sock")
    end

    test "without a herdr socket it still lists, with '?' for status", %{main: main} do
      assert {:ok, [%{branch: "feat-a", status: "?"}]} = Mice.list(main, herdr_socket: nil)
    end
  end
end
