defmodule Whiska.Hook.UserPromptSubmit do
  @moduledoc """
  One prompt in a mouse's session in; the answer the person saved for it out,
  as context for that turn (ADR-next-an-answer-is-taken-not-typed).

  This is the take. Claude Code runs the hook inside the session the prompt was
  submitted to, so an answer printed here has reached that session — which is
  what `taken_at` records, and what the owl stops ringing for. The answer never
  goes through the terminal, so a multi-line one arrives exactly as written.

  Any prompt hands over what is waiting, not only the doorbell: the person
  typing into the pane by hand delivers an answer the owl gave up on.

  The stamp comes after the read and its failure does not stop the print: a
  failed stamp means the answer may be handed over twice, never not at all.

  The hook shim exits before this runs unless the worktree's answer flag is
  set (`Whiska.AnswerFlag`), so a session with nothing waiting never starts the
  escript.
  """

  alias Whiska.AnswerFlag
  alias Whiska.Delivery.Text
  alias Whiska.Isolated
  alias Whiska.Marker
  alias Whiska.Schema.Question
  alias Whiska.Session
  alias Whiska.Storage

  @doc "The hook's stdout for one payload, or `:none` to print nothing."
  @spec run(String.t()) :: String.t() | :none
  def run(raw_payload) do
    with {:ok, payload} <- decode(raw_payload),
         {:ok, layout} <- Session.worktree(payload),
         {:ok, [_ | _] = answers} <- Isolated.run(fn -> hand_over(layout) end) do
      encode(answers)
    else
      {:error, reason} when reason != :not_a_mouse ->
        warn("could not hand over a saved answer (#{inspect(reason)})")
        :none

      _nothing ->
        :none
    end
  end

  defp hand_over(layout) do
    case Storage.open(layout.main_checkout) do
      {:ok, handle} ->
        try do
          if Session.main_pane?(Storage.main_pane()), do: {:ok, []}, else: take(layout)
        after
          Storage.close(handle)
        end

      other ->
        other
    end
  end

  defp take(layout) do
    with {:ok, mouse_id} <- Marker.read_or_mint(layout.worktree_root) do
      answers = Storage.chased(mouse_id)
      stamp(mouse_id, answers)
      AnswerFlag.clear(layout.worktree_root)
      {:ok, answers}
    end
  end

  defp stamp(_mouse_id, []), do: :ok

  defp stamp(mouse_id, answers) do
    now = DateTime.utc_now()
    Storage.take(Enum.map(answers, & &1.id), now)
    # Taking an answer is a turn beginning (ADR-0067).
    Storage.set_working(mouse_id, now)
  rescue
    error -> warn("handed the answer over but could not stamp it (#{Exception.message(error)})")
  end

  defp encode(answers) do
    JSON.encode!(%{
      "hookSpecificOutput" => %{
        "hookEventName" => "UserPromptSubmit",
        "additionalContext" => Enum.map_join(answers, "\n\n", &context/1)
      }
    })
  end

  defp context(%Question{id: id, text: text, answer: answer}) do
    asked = Text.pointer(text || "")
    about = if asked, do: " (you asked #{asked})", else: ""
    "The person's answer to your question ##{id}#{about}:\n\n#{answer}"
  end

  defp decode(raw) do
    case JSON.decode(raw) do
      {:ok, payload} when is_map(payload) -> {:ok, payload}
      _ -> {:error, :malformed_payload}
    end
  end

  defp warn(message), do: IO.puts(:stderr, "whiska: " <> message)
end
