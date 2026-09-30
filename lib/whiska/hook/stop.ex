defmodule Whiska.Hook.Stop do
  @moduledoc """
  One finished turn in, one entry on the doorstep out (ADR-0036).

  The hook never opens a socket. It reads the `Stop` payload, works out which
  house this worktree belongs to, and writes the mouse's whole final message to
  that house's doorstep, whether or not the owl is running. There is no second
  code path for "the owl is down", because there is no first one.

  It reads one thing out of the house before it writes: the pane `whiska start`
  recorded as the main session. A stop firing in that pane is the person's own
  session, not a mouse, and nothing is left behind (ADR-0053).

  It writes on every turn that ended. A turn with a subagent still out has not
  ended — Claude Code will wake this session when the subagent reports — and
  that one is passed over in silence (ADR-0052).

  It does not classify. The marker is read by the owl on collection (ADR-0009),
  so a message with no marker is written exactly like one with a `done` in it:
  forgetting the marker has to make noise, and that decision belongs to the
  reader, not the writer.

  Outside a worktree — the main session, or any repo Whiska is merely installed
  in — this is a no-op: there is no mouse here to speak for. Which session this
  is comes from `Whiska.Session`, not from the working directory it was handed
  (ADR-0053).

  ## Why this is Elixir when ADR-0033 says hooks go native

  ADR-0033's measurement is about `PreToolUse`, which fires on every tool call.
  `Stop` fires once per turn, so the ~200 ms escript start is paid a few times a
  minute at most. The final shape here — read JSON, write a file — is the same
  thirty lines in C whenever the native hook is written, and `whiska init`'s
  shim means `settings.json` will not change when it is (ADR-0035).
  """

  alias Whiska.Doorstep
  alias Whiska.Doorstep.Entry
  alias Whiska.Marker
  alias Whiska.Session
  alias Whiska.Transcript

  @doc "Handle one Stop payload. Always `:ok`; problems go to stderr."
  @spec run(String.t()) :: :ok
  def run(raw_payload) do
    with {:ok, payload} <- decode(raw_payload),
         {:ok, layout} <- Session.worktree(payload),
         false <- Session.main_session?(layout.main_checkout),
         :over <- turn_state(payload),
         {:ok, mouse_id} <- Marker.read_or_mint(layout.worktree_root),
         {:ok, _file} <- leave(layout, mouse_id, message(payload)) do
      :ok
    else
      :in_flight ->
        :ok

      true ->
        :ok

      {:error, :not_a_mouse} ->
        :ok

      {:error, reason} ->
        warn("could not leave the question on the doorstep (#{inspect(reason)})")

      :error ->
        :ok
    end
  end

  # A turn that launched a subagent and has not been handed its report is not
  # over: Claude Code ends the turn and wakes the session when the subagent
  # reports (ADR-0052). Writing here would leave "still waiting on the
  # reviewers" on the doorstep as an unmarked question that asks nothing.
  defp turn_state(%{"transcript_path" => path}) when is_binary(path) do
    if path |> Transcript.tail() |> Transcript.subagents_in_flight?(),
      do: :in_flight,
      else: :over
  end

  defp turn_state(_no_transcript), do: :over

  defp leave(layout, mouse_id, text) do
    Doorstep.leave(layout.main_checkout, %Entry{
      mouse_id: mouse_id,
      branch: layout.branch_label,
      worktree_root: layout.worktree_root,
      stamped_at: DateTime.utc_now(),
      text: text
    })
  end

  defp decode(raw) do
    case JSON.decode(raw) do
      {:ok, payload} when is_map(payload) ->
        {:ok, payload}

      _ ->
        warn("could not parse the Stop payload — nothing left on the doorstep")
        :error
    end
  end

  defp message(%{"last_assistant_message" => text}) when is_binary(text), do: text
  defp message(_), do: ""

  defp warn(message) do
    IO.puts(:stderr, "whiska: #{message}")
    :ok
  end
end
