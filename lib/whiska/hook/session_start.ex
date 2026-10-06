defmodule Whiska.Hook.SessionStart do
  @moduledoc """
  The rules a session starts with (ADR-next-rules-arrive-by-role).

  Claude Code runs this on every `SessionStart` — a new session, a resume, a
  `/clear` and a compaction — and adds what it prints to the session's context.
  That is what keeps the rules alive after `/compact`: they are said again.

  Which rules depends on the session's role:

  - **Outside herdr** (`HERDR_ENV` is not `1`): nothing. No mouse can be
    spawned and nothing is delivered there, so the protocol is dead weight.
  - **A mouse**: a session that started in a `worktrees/<branch>` worktree and
    is not in the pane `whiska start` recorded — the reading the `Stop` hook
    already makes (ADR-0053).
  - **The main session**: anything else in herdr.

  A part the person holds as `keep` in `~/.claude/CLAUDE.md` or the project's
  own `CLAUDE.md` is left out: Claude Code loads those files itself, so their
  wording is already in context (ADR-0045).

  Fails quiet: a payload that will not parse, or a role that cannot be read,
  prints nothing rather than the wrong rules.
  """

  alias Whiska.ClaudeMd
  alias Whiska.Rules
  alias Whiska.Session

  @doc """
  Handle one `SessionStart` payload, with the environment it fired in.

  Prints the hook's JSON on stdout, or nothing. Always `:ok`.
  """
  @spec run(String.t(), %{optional(String.t()) => String.t()}) :: :ok
  def run(raw_payload, env) when is_map(env) do
    with "1" <- env["HERDR_ENV"],
         {:ok, payload} <- decode(raw_payload) do
      role = role(payload)

      payload
      |> claude_mds(env)
      |> Enum.flat_map(&kept_in/1)
      |> then(&Rules.render(role, &1))
      |> encode()
      |> IO.write()
    end

    :ok
  end

  defp role(payload) do
    with {:ok, layout} <- Session.worktree(payload),
         false <- Session.main_session?(layout.main_checkout) do
      :mouse
    else
      _ -> :main
    end
  end

  # The two files a `keep` can sit in that Claude Code loads for this session.
  # The project directory is the one the hook was given, then the payload's.
  defp claude_mds(payload, env) do
    project = env["CLAUDE_PROJECT_DIR"] || payload["cwd"]

    [
      env["HOME"] && Path.join(env["HOME"], ".claude/CLAUDE.md"),
      project && Path.join(project, "CLAUDE.md")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp kept_in(path) do
    case File.read(path) do
      {:ok, contents} -> ClaudeMd.kept(contents)
      {:error, _} -> []
    end
  end

  defp decode(raw) do
    case JSON.decode(raw) do
      {:ok, payload} when is_map(payload) -> {:ok, payload}
      _ -> :error
    end
  end

  defp encode(rules) do
    JSON.encode!(%{
      "hookSpecificOutput" => %{
        "hookEventName" => "SessionStart",
        "additionalContext" => rules
      }
    })
  end
end
