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

  alias Whiska.Layout
  alias Whiska.Marker
  alias Whiska.Rule.MainCheckout
  alias Whiska.Rule.Sniff
  alias Whiska.Storage

  @type decision :: :allow | {:deny, String.t()}

  @doc """
  Decide one PreToolUse event, given its raw JSON payload.
  """
  @spec run(String.t()) :: decision()
  def run(raw_payload) do
    with {:ok, payload} when is_map(payload) <- decode(raw_payload),
         {:ok, cwd} <- fetch_cwd(payload),
         {:ok, layout} <- Layout.resolve(cwd) do
      decide(tool_name(payload), tool_input(payload), layout, remember(layout))
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

  # Sniff runs first, and deliberately so. When a sniff mouse edits the main
  # checkout both rules would fire, and "you are in sniff mode" is the reason
  # that actually explains what happened; "that path is outside your worktree"
  # would send it to fix the wrong thing.
  defp decide(tool_name, tool_input, layout, mode) do
    case Sniff.decide(tool_name, tool_input, mode) do
      {:deny, _} = denial -> denial
      :allow -> MainCheckout.decide(tool_name, tool_input, layout)
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

  defp fetch_cwd(payload) do
    case payload do
      %{"cwd" => cwd} when is_binary(cwd) -> {:ok, cwd}
      _ -> File.cwd()
    end
  end

  defp tool_name(%{"tool_name" => name}) when is_binary(name), do: name
  defp tool_name(_), do: ""

  defp tool_input(%{"tool_input" => input}) when is_map(input), do: input
  defp tool_input(_), do: %{}

  # Identity is minted lazily, on the first hook invocation inside a worktree that
  # has no marker file yet (ADR-0002, ADR-0030) — and it happens whether the call
  # is allowed or denied, since a denied call still came from a real mouse.
  #
  # Minting is plain file I/O and runs here. Opening the house runs in an
  # isolated, *unlinked* process: `Repo.start_link` links the repo supervisor to
  # whoever starts it, so a database that will not open takes its starter down
  # with it. Letting that reach the entry point would turn a storage problem into
  # "every tool call in this session dies", which is exactly the failure the rule
  # is supposed to be independent of.
  @default_mode "build"

  defp remember(layout) do
    with {:ok, mouse_id} <- Marker.read_or_mint(layout.worktree_root),
         {:ok, mode} <- isolated(fn -> record(layout, mouse_id) end) do
      mode
    else
      other ->
        # Falling back to build rather than sniff is deliberate. build is the
        # default and the common case; assuming sniff would block every edit in
        # ordinary work over a database hiccup. This degrades sniff to build,
        # never to unprotected — worktree containment is pure path arithmetic
        # and does not consult the database at all.
        warn("could not read this mouse's mode (#{inspect(other)}) — assuming #{@default_mode}")
        @default_mode
    end
  end

  defp record(layout, mouse_id) do
    case Storage.open(layout.main_checkout) do
      {:ok, handle} ->
        try do
          Storage.record_mouse(%{
            mouse_id: mouse_id,
            path: layout.worktree_root,
            branch: layout.branch_label
          })

          Storage.mode(mouse_id)
        after
          Storage.close(handle)
        end

      other ->
        other
    end
  end

  @isolation_timeout 5_000

  defp isolated(work) do
    parent = self()
    {pid, ref} = spawn_monitor(fn -> send(parent, {__MODULE__, self(), work.()}) end)

    receive do
      {__MODULE__, ^pid, result} ->
        Process.demonitor(ref, [:flush])
        result

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:error, reason}
    after
      @isolation_timeout ->
        Process.demonitor(ref, [:flush])
        Process.exit(pid, :kill)
        {:error, :timeout}
    end
  end

  defp warn(message), do: IO.puts(:stderr, "whiska: #{message}")
end
