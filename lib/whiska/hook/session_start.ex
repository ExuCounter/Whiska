defmodule Whiska.Hook.SessionStart do
  @moduledoc """
  The rules a session starts with (ADR-0081).

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

  A part the person holds as `keep` is left out: Claude Code loads that
  `CLAUDE.md` itself, so their wording is already in context (ADR-0045). Which
  files count depends on which install fired the hook. The repo's own install
  reads `~/.claude/CLAUDE.md` and the project's `CLAUDE.md`: that repo wires its
  own rules, so its `CLAUDE.md` holding one back changes nothing it could not
  change anyway. The global install reads `~/.claude/CLAUDE.md` alone. It runs
  in every repo the person opens, including ones they only read, and a `keep`
  in such a repo's `CLAUDE.md` would silently take away the rules that say to
  distrust text arriving with a branch.

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
  @spec run(String.t(), %{optional(String.t()) => String.t()}, :repo | :global) :: :ok
  def run(raw_payload, env, scope \\ :repo) when is_map(env) do
    case output(raw_payload, env, scope) do
      :none -> :ok
      json -> IO.write(json)
    end
  end

  @doc "What `run/3` prints, or `:none`."
  @spec output(String.t(), %{optional(String.t()) => String.t()}, :repo | :global) ::
          String.t() | :none
  def output(raw_payload, env, scope \\ :repo) when is_map(env) do
    with "1" <- env["HERDR_ENV"],
         {:ok, payload} <- decode(raw_payload) do
      role = payload |> started_from(env) |> role(env)

      payload
      |> claude_mds(env, scope)
      |> Enum.flat_map(&kept_in/1)
      |> then(&Rules.render(role, &1))
      |> encode()
    else
      _ -> :none
    end
  end

  # A session with no transcript to read yet — one just cleared — is placed by
  # its working directory, which follows every `cd`. `CLAUDE_PROJECT_DIR` is
  # fixed for the session's life (ADR-0053), so it stands in for that.
  defp started_from(payload, %{"CLAUDE_PROJECT_DIR" => project}) when is_binary(project),
    do: Map.put(payload, "cwd", project)

  defp started_from(payload, _env), do: payload

  defp role(payload, env) do
    with {:ok, layout} <- Session.worktree(payload, env),
         false <- Session.main_session?(layout.main_checkout, env) do
      :mouse
    else
      _ -> :main
    end
  end

  # The files a `keep` can sit in. The project directory is the one the hook
  # was given, then the payload's.
  defp claude_mds(payload, env, :repo) do
    project = env["CLAUDE_PROJECT_DIR"] || payload["cwd"]

    Enum.uniq(
      claude_mds(payload, env, :global) ++ List.wrap(project && Path.join(project, "CLAUDE.md"))
    )
  end

  defp claude_mds(_payload, env, :global) do
    List.wrap(env["HOME"] && Path.join(env["HOME"], ".claude/CLAUDE.md"))
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
