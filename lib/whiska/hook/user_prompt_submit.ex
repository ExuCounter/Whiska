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

  Reading and stamping are two openings of the house, read first. A stamp that
  fails, or is cut off, still lets the answer print, and leaves the flag up so
  the next prompt hands it over again: an answer may arrive twice, never not at
  all.

  The answers are the mouse's whose marker this worktree carries, and only
  while its record still says it works here. A marker is a plain file a mouse
  can copy (ADR-0002), and an answer handed to the wrong session is one the
  owl stops ringing for (ADR-0005).

  The hook shim exits before this runs unless the worktree's answer flag is
  set (`Whiska.AnswerFlag`), so a session with nothing waiting never starts the
  escript.
  """

  alias Whiska.AnswerFlag
  alias Whiska.Delivery.Text
  alias Whiska.Isolated
  alias Whiska.Layout
  alias Whiska.Marker
  alias Whiska.Schema.Mouse
  alias Whiska.Schema.Question
  alias Whiska.Session
  alias Whiska.Storage

  @doc "The hook's stdout for one payload, or `:none` to print nothing."
  @spec run(String.t()) :: String.t() | :none
  def run(raw_payload) do
    with {:ok, payload} <- decode(raw_payload),
         {:ok, layout} <- Session.worktree(payload),
         {:ok, waiting} <- Isolated.run(fn -> in_house(layout, &waiting/1) end) do
      hand_over(layout, waiting)
    else
      {:error, reason} when reason != :not_a_mouse ->
        warn("could not hand over a saved answer (#{inspect(reason)})")
        :none

      _nothing ->
        :none
    end
  end

  defp waiting(layout) do
    if Session.main_pane?(Storage.main_pane()),
      do: {:ok, :not_a_mouse},
      else: ours(layout)
  end

  defp ours(layout) do
    with {:ok, mouse_id} <- Marker.read_or_mint(layout.worktree_root) do
      case Storage.mouse(mouse_id) do
        %Mouse{path: path} when is_binary(path) ->
          if Layout.canonical(path) == Layout.canonical(layout.worktree_root),
            do: {:ok, {mouse_id, Storage.chased(mouse_id)}},
            else: {:ok, :not_a_mouse}

        _no_record ->
          {:ok, {mouse_id, []}}
      end
    end
  end

  defp hand_over(_layout, :not_a_mouse), do: :none

  defp hand_over(layout, {_mouse_id, []}) do
    AnswerFlag.clear(layout.worktree_root)
    :none
  end

  defp hand_over(layout, {mouse_id, answers}) do
    case Isolated.run(fn -> in_house(layout, fn _ -> stamp(mouse_id, answers) end) end) do
      {:ok, _} ->
        AnswerFlag.clear(layout.worktree_root)

      other ->
        warn("handed the answer over but could not stamp it (#{inspect(other)})")
    end

    encode(answers)
  end

  defp stamp(mouse_id, answers) do
    now = DateTime.utc_now()
    {:ok, _} = Storage.take(Enum.map(answers, & &1.id), now)
    # Taking an answer is a turn beginning (ADR-0067).
    {:ok, _} = Storage.set_working(mouse_id, now)
  end

  defp in_house(layout, work) do
    case Storage.open(layout.main_checkout) do
      {:ok, handle} ->
        try do
          work.(layout)
        after
          Storage.close(handle)
        end

      other ->
        other
    end
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
