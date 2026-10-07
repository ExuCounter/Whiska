defmodule Whiska.Hook.Stop do
  @moduledoc """
  One finished turn in, one entry on the doorstep out (ADR-0036).

  It reads the `Stop` payload, works out which house this worktree belongs to,
  and writes the mouse's whole final message to that house's doorstep. It runs
  inside the owl when the owl answers the hook socket, and in the escript when
  it does not; either way the entry lands on the same doorstep, so a dead owl
  still loses nothing (ADR-0036, amended).

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
  """

  alias Whiska.Doorstep
  alias Whiska.Doorstep.Entry
  alias Whiska.Marker
  alias Whiska.Session
  alias Whiska.Transcript

  @doc "Handle one Stop payload. Always `:ok`; problems go to stderr."
  @spec run(String.t(), map()) :: :ok
  def run(raw_payload, env \\ System.get_env()) do
    _ = leave(raw_payload, env)
    :ok
  end

  @doc """
  The same, saying which house an entry was left in, so the owl can collect it
  at once. `:ok` when there was nothing to leave, `{:error, reason}` when an
  entry could not be written — which the owl leaves to the escript to try.
  """
  @spec leave(String.t(), map()) :: {:left, Path.t()} | :ok | {:error, term()}
  def leave(raw_payload, env) do
    with {:ok, payload} <- decode(raw_payload),
         {:ok, layout} <- Session.worktree(payload, env),
         false <- Session.main_session?(layout.main_checkout, env),
         tail = transcript_tail(payload),
         :over <- turn_state(tail),
         {:ok, mouse_id} <- Marker.read_or_mint(layout.worktree_root),
         {:ok, _file} <- write(layout, mouse_id, message(payload), Transcript.ran_on(tail)) do
      {:left, layout.main_checkout}
    else
      :in_flight ->
        :ok

      true ->
        :ok

      {:error, :not_a_mouse} ->
        :ok

      {:error, reason} = error ->
        warn("could not leave the question on the doorstep (#{inspect(reason)})")
        error

      :error ->
        :ok
    end
  end

  # A turn that launched a subagent and has not been handed its report is not
  # over: Claude Code ends the turn and wakes the session when the subagent
  # reports (ADR-0052). Writing here would leave "still waiting on the
  # reviewers" on the doorstep as an unmarked question that asks nothing.
  defp turn_state(tail) do
    if Transcript.subagents_in_flight?(tail), do: :in_flight, else: :over
  end

  defp transcript_tail(%{"transcript_path" => path}) when is_binary(path),
    do: Transcript.tail(path)

  defp transcript_tail(_no_transcript), do: ""

  defp write(layout, mouse_id, text, ran_on) do
    Doorstep.leave(layout.main_checkout, %Entry{
      mouse_id: mouse_id,
      branch: layout.branch_label,
      worktree_root: layout.worktree_root,
      stamped_at: DateTime.utc_now(),
      text: text,
      ran_on: ran_on,
      spec: spec(layout.worktree_root)
    })
  end

  # The spec as it stands when the turn ends (ADR-0076). Anything but a plain
  # UTF-8 file of sane size is the same as absent: a pipe would hang the read,
  # and bytes JSON cannot carry would crash the encoder, and either would cost
  # the message itself its place on the doorstep.
  @spec_max_bytes 256 * 1024

  defp spec(worktree_root) do
    path = Path.join(worktree_root, Whiska.Spec.filename())

    with {:ok, %File.Stat{type: :regular, size: size}} when size <= @spec_max_bytes <-
           File.lstat(path),
         {:ok, text} <- File.read(path),
         true <- String.valid?(text) do
      text
    else
      _ -> nil
    end
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
