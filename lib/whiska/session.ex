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

  Both are best-effort by design. With no transcript, or none that names a
  directory, the payload's working directory is all there is and it is used. A
  house that will not open records no main pane, and then no pane claim is made
  either way. Neither fallback is worse than what identity was before them.
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
  @spec worktree(map()) :: {:ok, Layout.t()} | {:error, :not_a_mouse}
  def worktree(payload) do
    case payload |> started_in() |> Layout.resolve() do
      {:ok, layout} -> {:ok, layout}
      _no_worktree -> {:error, :not_a_mouse}
    end
  end

  @doc """
  The folder this session started in when it is under a `worktrees/` container
  but in no worktree of it.

  Read the same way as `worktree/1` — the transcript's first entry, then the
  payload's working directory (ADR-0053) — and carried only for containment,
  never for identity (`Whiska.Layout.unplaced/1`).
  """
  @spec unplaced(map()) :: {:ok, Layout.t()} | {:error, :not_a_mouse}
  def unplaced(payload) do
    case payload |> started_in() |> Layout.unplaced() do
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
  @spec main_pane?(String.t() | nil) :: boolean()
  def main_pane?(nil), do: false

  def main_pane?(recorded) when is_binary(recorded) do
    System.get_env("HERDR_PANE_ID") == recorded
  end

  @doc """
  The same question for a caller that has to go and read the house for it.

  Outside herdr there is no pane to compare, and the house is left shut. When
  there is one, opening the house runs through `Whiska.Isolated`: a caller
  asking this has work of its own that must survive a database that will not
  open, and an unreadable house makes no claim either way.
  """
  @spec main_session?(Path.t()) :: boolean()
  def main_session?(main_checkout) do
    case System.get_env("HERDR_PANE_ID") do
      nil -> false
      pane -> pane == Isolated.run(fn -> Waiting.main_session(main_checkout) end)
    end
  end

  defp started_in(payload) do
    from_transcript(payload) || cwd(payload)
  end

  defp from_transcript(%{"transcript_path" => path}) when is_binary(path),
    do: Transcript.started_in(path)

  defp from_transcript(_no_transcript), do: nil

  defp cwd(%{"cwd" => cwd}) when is_binary(cwd), do: cwd

  defp cwd(_no_cwd) do
    case File.cwd() do
      {:ok, cwd} -> cwd
      {:error, _} -> "/"
    end
  end
end
