defmodule Whiska.Hook.PreToolUse do
  @moduledoc """
  One tool call in, one decision out.

  ADR-0011 puts hard rules here rather than in `CLAUDE.md`: a line in `CLAUDE.md`
  is a suggestion that works only if the mouse chooses to follow it, whereas a
  `PreToolUse` hook runs before the tool call and can actually block it.

  ## Failing open, loudly

  A malformed payload, or a house that will not open, allows the call through and
  writes a diagnostic to stderr rather than denying. This is a deliberate trade:
  failing closed would let one bad payload brick every tool call in a session with
  no way out, and the blast radius of that is far larger than the hole it closes.
  Loud-but-allowing keeps the failure visible. The narrower ADR-0011 rule — deny
  *immediately* rather than block-and-wait — is about approval flows, which this
  slice does not have.

  The hold is the one rule here, since the person sets it while the mouse runs
  (ADR-0079). What a mouse's mode forbids, and the person's commands, are the
  deny list it is started with, which Claude Code enforces itself
  (ADR-next-a-mouse-starts-in-bypass-mode).
  """

  alias Whiska.Isolated
  alias Whiska.Marker
  alias Whiska.Rule.Held
  alias Whiska.Schema.Mouse
  alias Whiska.Session
  alias Whiska.Storage

  @type decision :: :allow | {:deny, String.t()}

  @doc """
  Decide one PreToolUse event, given its raw JSON payload.
  """
  @spec run(String.t(), map()) :: decision()
  def run(raw_payload, env \\ System.get_env()), do: judge(raw_payload, env, &fall_back/2)

  @doc """
  The same decision, or `:unreadable` where `run/2` would fall back to not held
  because this mouse's house could not be read.

  The owl answers with this. A house the owl cannot open — its file
  descriptors run out, its database is locked — may still open for a fresh
  escript, so the owl leaves that call to it rather than answering with the
  weaker fallback (ADR-0033).
  """
  @spec judge(String.t(), map()) :: decision() | :unreadable
  def judge(raw_payload, env), do: judge(raw_payload, env, fn _layout, _ -> :unreadable end)

  defp judge(raw_payload, env, unreadable) do
    case decode(raw_payload) do
      {:ok, payload} when is_map(payload) -> placed(payload, env, unreadable)
      _ -> :allow
    end
  end

  # Only a session that started in a worktree is a mouse (ADR-0053); one in a
  # folder under `worktrees/` that is no worktree of its own is nobody
  # (ADR-0030), and nobody is ever held.
  defp placed(payload, env, unreadable) do
    case Session.worktree(payload, env) do
      {:ok, layout} -> as_mouse(layout, env, unreadable)
      {:error, :not_a_mouse} -> :allow
    end
  end

  defp as_mouse(layout, env, unreadable) do
    case identity(layout, env, unreadable) do
      {:mouse, held?} -> Held.decide(held?, layout.branch_label)
      :unreadable -> :unreadable
      _ -> :allow
    end
  end

  @doc """
  Render a decision as the hook's stdout.

  An allow deliberately produces nothing: staying silent leaves the rest of Claude
  Code's own permission machinery to have the final say, where emitting an
  explicit `"allow"` would short-circuit it.
  """
  @spec encode(decision()) :: String.t() | :none
  def encode(:allow), do: :none

  def encode({:deny, reason}) do
    JSON.encode!(%{
      "hookSpecificOutput" => %{
        "hookEventName" => "PreToolUse",
        "permissionDecision" => "deny",
        "permissionDecisionReason" => reason
      }
    })
  end

  defp decode(raw) do
    case JSON.decode(raw) do
      {:ok, payload} ->
        {:ok, payload}

      {:error, reason} ->
        warn("could not parse the PreToolUse payload (#{inspect(reason)}) — allowing the call")
        :error
    end
  end

  # The house answers two questions in one opening: whose pane this is, and
  # whether the mouse is held. A tool call firing in the pane `whiska start`
  # recorded is the person's own session — no mouse, no rules, nothing recorded
  # (ADR-0053).
  #
  # Otherwise identity is minted lazily, on the first invocation inside a worktree
  # that has no marker file yet (ADR-0002, ADR-0030) — and it happens whether the
  # call is allowed or denied, since a denied call still came from a real mouse.
  #
  # All of it runs through `Whiska.Isolated`, so a database that will not open
  # cannot turn a storage problem into "every tool call in this session dies",
  # which is exactly the failure the rule is supposed to be independent of.
  defp identity(layout, env, unreadable) do
    case Isolated.run(fn -> in_house(layout, env) end) do
      :main_session ->
        :main_session

      {:mouse, _held?} = mouse ->
        mouse

      other ->
        unreadable.(layout, other)
    end
  end

  # Falling back to not held keeps a database hiccup from stopping every mouse.
  # The marker is minted here too, so a house that will not open does not also
  # cost this mouse the identity ADR-0002 says it gets on its first invocation.
  defp fall_back(layout, reason) do
    Marker.read_or_mint(layout.worktree_root)
    warn("could not read whether this mouse is held (#{inspect(reason)}) — assuming not")
    {:mouse, false}
  end

  defp in_house(layout, env) do
    Storage.within(layout.main_checkout, fn ->
      if Session.main_pane?(Storage.main_pane(), env), do: :main_session, else: record(layout)
    end)
  end

  defp record(layout) do
    with {:ok, mouse_id} <- Marker.read_or_mint(layout.worktree_root) do
      Storage.record_mouse(%{
        mouse_id: mouse_id,
        path: layout.worktree_root,
        branch: layout.branch_label
      })

      case Storage.mouse(mouse_id) do
        nil -> {:error, :no_such_mouse}
        mouse -> {:mouse, held?(mouse)}
      end
    end
  end

  defp held?(%Mouse{held_at: %DateTime{}}), do: true
  defp held?(_mouse), do: false

  defp warn(message), do: IO.puts(:stderr, "whiska: #{message}")
end
