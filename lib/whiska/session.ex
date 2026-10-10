defmodule Whiska.Session do
  @moduledoc """
  Which session a hook is firing in: the mouse it belongs to, or nobody
  (ADR-0053).

  A session is identified by where it started and which pane it runs in. Both
  are fixed for its whole life. The working directory Claude Code passes a hook
  is not: it follows every `cd` the session runs, so a main session that stepped
  into `worktrees/<branch>` reads as that branch's mouse and files the person's
  own reply as a message from it, and a mouse that stepped out reads as nobody
  and loses its message.

  Two signals, and the pane is the stronger one. A hook firing in the pane
  `whiska start` recorded is the main session whatever any directory says. The
  other is the transcript Claude Code writes: its first entry names the
  directory the session was started in, which is the worktree the mouse speaks
  for even when its shell has wandered elsewhere.

  A third signal says when a session speaks for nobody at all: a Claude Code
  session running underneath another one — a test script or a `claude -p` the
  mouse started in its own worktree — is nested
  (ADR-next-a-nested-session-speaks-for-nobody). It starts where the mouse
  started and runs in the mouse's pane, so neither signal above can tell it
  apart; the process tree can.

  Both are best-effort by design. With no transcript, or none that names a
  directory, the payload's working directory is all there is and it is used. A
  house that will not open records no main pane, and then no pane claim is made
  either way. Neither fallback is worse than what identity was before them.

  Every function takes the environment the hook fired in, defaulting to this
  VM's own. Inside the owl that default is the owl's environment, not the
  hook's, so the owl always passes the one the hook shim sent.
  """

  alias Whiska.Isolated
  alias Whiska.Layout
  alias Whiska.Transcript
  alias Whiska.Waiting

  @doc """
  The worktree this session started in, as a layout.

  `{:error, :not_a_mouse}` when it started in the main checkout, or anywhere
  else outside a `worktrees/<branch>/` folder.
  """
  @spec worktree(map(), map()) :: {:ok, Layout.t()} | {:error, :not_a_mouse}
  def worktree(payload, env \\ System.get_env()) do
    case payload |> started_in(env) |> Layout.resolve() do
      {:ok, layout} -> {:ok, layout}
      _no_worktree -> {:error, :not_a_mouse}
    end
  end

  @doc """
  The main checkout this session started in: a folder whose `.git` is a
  directory. `{:error, :not_a_main_checkout}` anywhere else.
  """
  @spec main_checkout(map(), map()) :: {:ok, Path.t()} | {:error, :not_a_main_checkout}
  def main_checkout(payload, env \\ System.get_env()) do
    dir = started_in(payload, env)

    if File.dir?(Path.join(dir, ".git")),
      do: {:ok, dir},
      else: {:error, :not_a_main_checkout}
  end

  @doc """
  The folder this session started in when it is under a `worktrees/` container
  but in no worktree of it.

  Read the same way as `worktree/1` — the transcript's first entry, then the
  payload's working directory (ADR-0053) — and carried only for containment,
  never for identity (`Whiska.Layout.unplaced/1`).
  """
  @spec unplaced(map(), map()) :: {:ok, Layout.t()} | {:error, :not_a_mouse}
  def unplaced(payload, env \\ System.get_env()) do
    case payload |> started_in(env) |> Layout.unplaced() do
      {:ok, layout} -> {:ok, layout}
      _no_folder -> {:error, :not_a_mouse}
    end
  end

  @doc """
  Is this hook firing in the pane the house calls its main session?

  For a caller that has the house open already and can read the pane itself.
  `recorded` is that pane as `whiska start` left it (ADR-0020), and the pane this
  invocation is in comes from herdr's own `HERDR_PANE_ID`. Outside herdr there is
  nothing to compare, and the answer is no.
  """
  @spec main_pane?(String.t() | nil, map()) :: boolean()
  def main_pane?(recorded, env \\ System.get_env())

  def main_pane?(nil, _env), do: false

  def main_pane?(recorded, env) when is_binary(recorded) do
    env["HERDR_PANE_ID"] == recorded
  end

  @doc """
  The same question for a caller that has to go and read the house for it.

  Outside herdr there is no pane to compare, and the house is left shut. When
  there is one, opening the house runs through `Whiska.Isolated`: a caller
  asking this has work of its own that must survive a database that will not
  open, and an unreadable house makes no claim either way.
  """
  @spec main_session?(Path.t(), map()) :: boolean()
  def main_session?(main_checkout, env \\ System.get_env()) do
    case env["HERDR_PANE_ID"] do
      nil -> false
      pane -> pane == Isolated.run(fn -> Waiting.main_session(main_checkout) end)
    end
  end

  @doc """
  Is this hook firing in a Claude Code session that runs underneath another
  one (ADR-next-a-nested-session-speaks-for-nobody)?

  `CLAUDE_PID` is the `claude` process that fired the hook. The walk starts at
  its parent, so the hook's own session never counts against itself. Any
  ancestor named `claude` makes it nested. The walk stops at `herdr`: a pane is
  where a session begins, so a herdr started from inside some `claude` does
  not make every mouse in it nested.

  When the walk cannot be made — no `CLAUDE_PID`, `ps` failing or hanging — the
  answer is no: a nested session's message delivered is noise, the mouse's
  message lost is worse (ADR-0009).
  """
  @spec nested?(map()) :: boolean()
  def nested?(env \\ System.get_env()) do
    with pid when is_binary(pid) <- env["CLAUDE_PID"],
         {:ok, table} <- processes(),
         %{ppid: parent} <- table[pid] do
      claude_above?(parent, table, 64)
    else
      _ -> false
    end
  end

  defp claude_above?(_pid, _table, 0), do: false

  defp claude_above?(pid, table, hops) do
    case table[pid] do
      %{comm: comm, ppid: parent} ->
        case Path.basename(comm) do
          "claude" -> true
          "herdr" -> false
          _other -> claude_above?(parent, table, hops - 1)
        end

      nil ->
        false
    end
  end

  # Every process at once, rather than one `ps` per hop: the chain from a
  # mouse up to herdr is a handful of hops, and one call is one fork. Bounded,
  # because inside the owl this runs on the hook socket's own clock.
  @ps_deadline 1_000

  defp processes do
    case Isolated.run(&ps/0, @ps_deadline) do
      {:ok, table} -> {:ok, table}
      _ -> :error
    end
  end

  defp ps do
    case System.cmd("ps", ["-A", "-o", "pid=,ppid=,comm="], stderr_to_stdout: true) do
      {out, 0} -> {:ok, out |> String.split("\n", trim: true) |> Map.new(&process/1)}
      _ -> :error
    end
  end

  defp process(line) do
    case line |> String.trim_leading() |> String.split(~r/\s+/, parts: 3) do
      [pid, ppid, comm] -> {pid, %{ppid: ppid, comm: comm}}
      _ -> {nil, nil}
    end
  end

  defp started_in(payload, env) do
    from_transcript(payload) || cwd(payload, env)
  end

  defp from_transcript(%{"transcript_path" => path}) when is_binary(path),
    do: Transcript.started_in(path)

  defp from_transcript(_no_transcript), do: nil

  defp cwd(%{"cwd" => cwd}, _env) when is_binary(cwd), do: cwd
  defp cwd(_no_cwd, %{"PWD" => "/" <> _ = pwd}), do: pwd

  defp cwd(_no_cwd, _env) do
    case File.cwd() do
      {:ok, cwd} -> cwd
      {:error, _} -> "/"
    end
  end
end
