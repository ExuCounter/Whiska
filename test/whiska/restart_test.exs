defmodule Whiska.RestartTest do
  @moduledoc """
  Restarting a mouse herdr restored without its launch flags (ADR-0069,
  ADR-0090, ADR-0044).

  A real house and herdr faked at the one boundary that allows it (ADR-0031).
  Most of these are about *not* typing `/exit`: ending a Claude session is
  what the preconditions exist to keep rare.
  """
  use ExUnit.Case, async: true

  import Mox

  alias Whiska.Herdr.Mock, as: Herdr
  alias Whiska.Restart
  alias Whiska.Spawn
  alias Whiska.Storage
  alias Whiska.Test.GitRepo

  setup :verify_on_exit!

  @flags ~w(--model sonnet --effort medium --fallback-model opus --autocompact 300000
            --dangerously-skip-permissions --settings .whiska-settings.json
            --append-system-prompt-file .whiska-brief.md)

  setup do
    root = Path.join(System.tmp_dir!(), "whiska-restart-#{Whiska.Test.Unique.id()}")
    File.mkdir_p!(root)
    repo = GitRepo.create(root)
    {:ok, handle} = Storage.open(repo.checkout, name: nil)

    on_exit(fn ->
      Storage.close(handle)
      File.rm_rf!(root)
    end)

    stub(Herdr, :read_screen, fn _, _ -> {:ok, "────\n❯\u00a0\n────\n"} end)
    {:ok, repo: repo}
  end

  defp mouse(repo, branch, opts \\ []) do
    path = GitRepo.worktree(repo, branch)
    id = "m-#{branch}"
    {:ok, _} = Storage.record_mouse(%{mouse_id: id, path: path, branch: branch})

    if Keyword.get(opts, :shaped, true),
      do: {:ok, _} = Storage.shape(id, "build", "sonnet", "medium")

    if Keyword.get(opts, :files, true) do
      File.write!(Path.join(path, ".whiska-brief.md"), "brief")
      File.write!(Path.join(path, ".whiska-settings.json"), "{}")
    end

    stub(Herdr, :worktrees, fn "/s", _checkout ->
      {:ok, [%{path: path, branch: branch, workspace_id: "ws-1"}]}
    end)

    %{id: id, path: path, branch: branch}
  end

  defp pane(mouse, opts \\ []) do
    %{
      pane_id: Keyword.get(opts, :pane_id, "w1:p1"),
      cwd: mouse.path,
      agent: Keyword.get(opts, :agent, "claude"),
      agent_status: Keyword.get(opts, :status, "idle"),
      title: nil,
      session: Keyword.get(opts, :session, "s-1")
    }
  end

  defp argv(args) do
    stub(Herdr, :processes, fn "/s", _ -> {:ok, [%{name: "claude", argv: ["claude" | args]}]} end)
  end

  # What herdr says of the pane: the mouse still running Claude at the re-check
  # before `/exit`, then gone once it was typed.
  defp exits(m) do
    typed = :counters.new(1, [])

    stub(Herdr, :prompt, fn "/s", "w1:p1", "/exit" ->
      :counters.put(typed, 1, 1)
      :ok
    end)

    stub(Herdr, :pane, fn "/s", "w1:p1" ->
      if :counters.get(typed, 1) == 1, do: {:ok, %{pane(m) | agent: nil}}, else: {:ok, pane(m)}
    end)
  end

  defp sweep(repo, panes, opts \\ []) do
    Restart.sweep(%{
      main_checkout: repo.checkout,
      herdr: Herdr,
      socket: "/s",
      panes: {:ok, panes},
      main_pane: Keyword.get(opts, :main_pane),
      restarted: Keyword.get(opts, :restarted, MapSet.new()),
      pause_ms: 0
    })
  end

  test "a restored mouse is exited and started again with its resume id and every flag", ctx do
    m = mouse(ctx.repo, "fix/x")
    argv(["--resume", "s-1"])
    exits(m)

    expect(Herdr, :start_agent, fn "/s", "w1:p1", "fix-x", args ->
      assert args == ["--resume", "s-1" | @flags]

      assert args ==
               [
                 "--resume",
                 "s-1"
                 | Spawn.launch_flags(%{mode: "build", model: "sonnet", effort: "medium"})
               ]

      {:ok, []}
    end)

    assert [{"m-fix/x", :restarted}] = sweep(ctx.repo, [pane(m)])
  end

  test "a mouse already started with its flags is left alone", ctx do
    m = mouse(ctx.repo, "fix/x")
    argv(@flags)
    assert [{"m-fix/x", {:left, :flagged}}] = sweep(ctx.repo, [pane(m)])
  end

  test "a mouse nobody shaped is left alone", ctx do
    m = mouse(ctx.repo, "fix/x", shaped: false)
    assert [{"m-fix/x", {:left, :unshaped}}] = sweep(ctx.repo, [pane(m)])
  end

  test "a shaped mouse whose brief or deny list is gone, or is a link, is left alone", ctx do
    m = mouse(ctx.repo, "fix/x", files: false)
    assert [{"m-fix/x", {:left, :no_files}}] = sweep(ctx.repo, [pane(m)])

    File.write!(Path.join(m.path, "elsewhere"), "{}")
    File.write!(Path.join(m.path, ".whiska-brief.md"), "brief")
    File.ln_s!(Path.join(m.path, "elsewhere"), Path.join(m.path, ".whiska-settings.json"))
    assert [{"m-fix/x", {:left, :no_files}}] = sweep(ctx.repo, [pane(m)])
  end

  test "a pane that is working, blocked or without a usable session is left alone", ctx do
    m = mouse(ctx.repo, "fix/x")
    assert [{_, {:left, {:not_ready, "working"}}}] = sweep(ctx.repo, [pane(m, status: "working")])
    assert [{_, {:left, {:not_ready, "blocked"}}}] = sweep(ctx.repo, [pane(m, status: "blocked")])
    assert [{_, {:left, :no_session}}] = sweep(ctx.repo, [pane(m, session: nil)])
    assert [{_, {:left, :no_session}}] = sweep(ctx.repo, [pane(m, session: "--model")])
    assert [{_, {:left, :no_session}}] = sweep(ctx.repo, [pane(m, session: "a b; rm")])
  end

  test "the main session's pane is never restarted", ctx do
    m = mouse(ctx.repo, "fix/x")
    assert [{_, {:left, :main_session}}] = sweep(ctx.repo, [pane(m)], main_pane: "w1:p1")
  end

  test "a pane with a draft in its prompt box is left alone", ctx do
    m = mouse(ctx.repo, "fix/x")
    stub(Herdr, :read_screen, fn _, _ -> {:ok, "────\n❯ half a sentence\n────\n"} end)
    argv(["--resume", "s-1"])
    assert [{_, {:left, :typing}}] = sweep(ctx.repo, [pane(m)])
  end

  test "a screen herdr cannot read is no permission to restart", ctx do
    m = mouse(ctx.repo, "fix/x")
    stub(Herdr, :read_screen, fn _, _ -> {:error, :no_screen} end)
    argv(["--resume", "s-1"])
    assert [{_, {:left, :unreadable}}] = sweep(ctx.repo, [pane(m)])
  end

  test "a process list herdr cannot read is no permission to restart", ctx do
    m = mouse(ctx.repo, "fix/x")
    stub(Herdr, :processes, fn "/s", _ -> {:error, :boom} end)
    assert [{_, {:left, :unreadable}}] = sweep(ctx.repo, [pane(m)])

    stub(Herdr, :processes, fn "/s", _ -> {:ok, []} end)
    assert [{_, {:left, :unreadable}}] = sweep(ctx.repo, [pane(m)])

    stub(Herdr, :processes, fn "/s", _ -> {:ok, [%{name: "claude", argv: []}]} end)
    assert [{_, {:left, :unreadable}}] = sweep(ctx.repo, [pane(m)])

    stub(Herdr, :processes, fn "/s", _ -> {:ok, [%{name: "node", argv: []}]} end)
    assert [{_, {:left, :unreadable}}] = sweep(ctx.repo, [pane(m)])
  end

  test "a worktree herdr does not list for this checkout is left alone", ctx do
    m = mouse(ctx.repo, "fix/x")
    stub(Herdr, :worktrees, fn "/s", _ -> {:ok, []} end)
    argv(["--resume", "s-1"])
    assert [{_, {:left, :not_our_worktree}}] = sweep(ctx.repo, [pane(m)])
  end

  test "a mouse tried this run is not tried again while it stays flagless", ctx do
    m = mouse(ctx.repo, "fix/x")
    argv(["--resume", "s-1"])
    assert [{_, {:left, :tried}}] = sweep(ctx.repo, [pane(m)], restarted: MapSet.new(["m-fix/x"]))
  end

  test "a tried mouse seen with its flags is reported flagged, so the house forgets it", ctx do
    m = mouse(ctx.repo, "fix/x")
    argv(@flags)

    assert [{_, {:left, :flagged}}] =
             sweep(ctx.repo, [pane(m)], restarted: MapSet.new(["m-fix/x"]))
  end

  test "a pane that went busy or grew a draft since it was judged is left alone", ctx do
    m = mouse(ctx.repo, "fix/x")
    argv(["--resume", "s-1"])
    stub(Herdr, :pane, fn "/s", "w1:p1" -> {:ok, pane(m, status: "working")} end)
    assert [{_, {:left, {:not_ready, "working"}}}] = sweep(ctx.repo, [pane(m)])

    calls = :counters.new(1, [])

    stub(Herdr, :read_screen, fn _, _ ->
      :counters.add(calls, 1, 1)

      if :counters.get(calls, 1) == 1,
        do: {:ok, "────\n❯\u00a0\n────\n"},
        else: {:ok, "────\n❯ draft\n────\n"}
    end)

    stub(Herdr, :pane, fn "/s", "w1:p1" -> {:ok, pane(m)} end)
    assert [{_, {:left, :typing}}] = sweep(ctx.repo, [pane(m)])
  end

  test "a /exit herdr refuses leaves the pane as it was", ctx do
    m = mouse(ctx.repo, "fix/x")
    argv(["--resume", "s-1"])
    stub(Herdr, :pane, fn _, _ -> {:ok, pane(m)} end)
    expect(Herdr, :prompt, fn _, _, "/exit" -> {:error, :boom} end)
    assert [{_, {:left, {:refused, :boom}}}] = sweep(ctx.repo, [pane(m)])
  end

  test "a Claude that does not exit is not started over", ctx do
    m = mouse(ctx.repo, "fix/x")
    argv(["--resume", "s-1"])
    expect(Herdr, :prompt, fn _, _, "/exit" -> :ok end)
    stub(Herdr, :pane, fn _, _ -> {:ok, pane(m)} end)
    assert [{_, {:left, :exit_timeout}}] = sweep(ctx.repo, [pane(m)])
  end

  test "a start herdr refuses is reported, not retried", ctx do
    m = mouse(ctx.repo, "fix/x")
    argv(["--resume", "s-1"])
    exits(m)
    expect(Herdr, :start_agent, fn _, _, _, _ -> {:error, :boom} end)
    assert [{_, {:left, {:start_refused, :boom}}}] = sweep(ctx.repo, [pane(m)])
  end

  test "a start refused as busy while the shell draws its prompt is tried again", ctx do
    m = mouse(ctx.repo, "fix/x")
    argv(["--resume", "s-1"])
    exits(m)
    busy = {:error, {:herdr, %{"code" => "agent_pane_busy"}}}
    expect(Herdr, :start_agent, 2, fn _, _, _, _ -> busy end)
    expect(Herdr, :start_agent, fn _, _, _, _ -> {:ok, []} end)
    assert [{_, :restarted}] = sweep(ctx.repo, [pane(m)])
  end

  test "no more than three mice are restarted in one sweep", ctx do
    ms = for n <- 1..4, do: mouse(ctx.repo, "fix/m#{n}")
    paths = Enum.map(ms, & &1.path)

    stub(Herdr, :worktrees, fn "/s", _ ->
      {:ok, Enum.map(paths, &%{path: &1, branch: nil, workspace_id: "ws"})}
    end)

    argv(["--resume", "s"])

    stub(Herdr, :prompt, fn _, id, "/exit" ->
      Process.put({:exited, id}, true)
      :ok
    end)

    panes = ms |> Enum.with_index() |> Enum.map(fn {m, i} -> pane(m, pane_id: "w1:p#{i}") end)
    by_id = Map.new(panes, &{&1.pane_id, &1})

    stub(Herdr, :pane, fn _, id ->
      if Process.get({:exited, id}), do: {:ok, %{by_id[id] | agent: nil}}, else: {:ok, by_id[id]}
    end)

    stub(Herdr, :start_agent, fn _, _, _, _ -> {:ok, []} end)
    outcomes = sweep(ctx.repo, panes)

    assert outcomes |> Enum.filter(&match?({_, :restarted}, &1)) |> length() == 3
    assert [{_, {:left, :later}}] = Enum.filter(outcomes, &match?({_, {:left, :later}}, &1))
  end
end
