defmodule Whiska.Hook.PreToolUse do
  @moduledoc """
  One tool call in, one decision out.

  ADR-0010 puts hard rules here rather than in `CLAUDE.md`: a line in `CLAUDE.md`
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

  The rule itself never depends on storage: identity and bookkeeping are
  best-effort, the decision is not.
  """

  alias Whiska.Isolated
  alias Whiska.Marker
  alias Whiska.Rule.Held
  alias Whiska.Rule.MainCheckout
  alias Whiska.Rule.Persons
  alias Whiska.Rule.Sniff
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
  The same decision, or `:unreadable` where `run/2` would fall back to build
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

  # A session that started in a worktree is a mouse and gets both rules. One
  # that started in a folder under `worktrees/` which is no worktree of its own
  # is nobody — no identity, no mode, nothing recorded (ADR-0030's note) — and
  # still gets containment: the main checkout is the one place it must not
  # write, and a folder Whiska cannot identify is where it is least able to
  # vouch for what happens (ADR-0013).
  defp placed(payload, env, unreadable) do
    case Session.worktree(payload, env) do
      {:ok, layout} -> as_mouse(payload, layout, env, unreadable)
      {:error, :not_a_mouse} -> as_nobody(payload, env)
    end
  end

  defp as_mouse(payload, layout, env, unreadable) do
    case identity(layout, env, unreadable) do
      {:mouse, mode, held?} -> decide(payload, layout, mode, held?, env)
      :unreadable -> :unreadable
      _ -> :allow
    end
  end

  defp as_nobody(payload, env) do
    with {:ok, layout} <- Session.unplaced(payload, env),
         false <- Session.main_session?(layout.main_checkout, env) do
      MainCheckout.decide(tool_name(payload), tool_input(payload), layout, where(payload, env))
    else
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

  # The hold runs first: it is the thing the person just did, and it refuses
  # every call whatever the mode. Then sniff, before containment, and
  # deliberately so: when a sniff mouse edits the main checkout both rules
  # would fire, and "you are in sniff mode" is the reason that actually explains
  # what happened; "that path is outside your worktree" would send it to fix
  # the wrong thing.
  defp decide(payload, layout, mode, held?, env) do
    tool_name = tool_name(payload)
    tool_input = tool_input(payload)

    with :allow <- Held.decide(held?, layout.branch_label),
         :allow <- Persons.decide(tool_name, tool_input),
         :allow <- Sniff.decide(tool_name, tool_input, mode) do
      MainCheckout.decide(tool_name, tool_input, layout, where(payload, env))
    end
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

  defp tool_name(%{"tool_name" => name}) when is_binary(name), do: name
  defp tool_name(_), do: ""

  defp tool_input(%{"tool_input" => input}) when is_map(input), do: input
  defp tool_input(_), do: %{}

  # Where the shell stands for this call: a position, never an identity
  # (ADR-0053). `~` and `$HOME` in a command are the hook's home.
  defp where(payload, env) do
    Enum.reject(
      [cwd: shell_cwd(payload), home: env["HOME"]],
      fn {_key, value} -> is_nil(value) end
    )
  end

  defp shell_cwd(%{"cwd" => "/" <> _ = cwd}), do: cwd
  defp shell_cwd(_payload), do: nil

  # The house answers two questions in one opening: whose pane this is, and what
  # mode the mouse is in. A tool call firing in the pane `whiska start` recorded
  # is the person's own session — no mouse, no rules, nothing recorded (ADR-0053).
  #
  # Otherwise identity is minted lazily, on the first invocation inside a worktree
  # that has no marker file yet (ADR-0002, ADR-0030) — and it happens whether the
  # call is allowed or denied, since a denied call still came from a real mouse.
  #
  # All of it runs through `Whiska.Isolated`, so a database that will not open
  # cannot turn a storage problem into "every tool call in this session dies",
  # which is exactly the failure the rule is supposed to be independent of.
  @default_mode "build"

  defp identity(layout, env, unreadable) do
    case Isolated.run(fn -> in_house(layout, env) end) do
      :main_session ->
        :main_session

      {:mouse, _mode, _held?} = mouse ->
        mouse

      other ->
        unreadable.(layout, other)
    end
  end

  # Falling back to build, and to not held, rather than to sniff is deliberate.
  # build is the common case; assuming sniff would block every edit in ordinary
  # work over a database hiccup. This degrades sniff, the wait on a mouse
  # nobody shaped (ADR-0069) and a hold to build, never to unprotected —
  # worktree containment is pure path arithmetic and does not consult the
  # database at all.
  #
  # The marker is minted here too, so a house that will not open does not also
  # cost this mouse the identity ADR-0002 says it gets on its first invocation.
  defp fall_back(layout, reason) do
    Marker.read_or_mint(layout.worktree_root)
    warn("could not read this mouse's mode (#{inspect(reason)}) — assuming #{@default_mode}")
    {:mouse, @default_mode, false}
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
        mouse -> {:mouse, Storage.mode_of(mouse), held?(mouse)}
      end
    end
  end

  defp held?(%Mouse{held_at: %DateTime{}}), do: true
  defp held?(_mouse), do: false

  defp warn(message), do: IO.puts(:stderr, "whiska: #{message}")
end
