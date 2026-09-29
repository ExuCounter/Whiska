defmodule Whiska.Delivery.Draft do
  @moduledoc """
  Whether the person has half-typed something in the main session's prompt box.

  The second half of ADR-0008's delivery gate, added by ADR-0047. herdr's
  `idle` says the model is not working; it says nothing about the person. When
  the owl types into a session whose box already holds a draft, the line lands
  inside that draft or submits it — the one thing delivery must never do.

  herdr exposes no input or keystroke signal (checked against herdr 0.8.2:
  `herdr api schema` has no such field and no such event; the three per-pane
  subscriptions are `pane.output_matched`, `pane.agent_status_changed` and
  `pane.scroll_changed`). What it does expose is the screen, and Claude Code's
  prompt box is on it. So this reads the screen — the one place in Whiska that
  does — and the reading is confined here, to plain code over a string, so that
  the guesswork is testable without herdr (ADR-0031).

  The rule is the last line that begins with Claude Code's prompt marker `❯`.
  Claude Code writes a non-breaking space after the marker and pads the line
  out to the box's width, so an empty box is the marker and nothing that is not
  whitespace. Anything else — a word, a `[Pasted text #5 +8 lines]` chip, the
  first line of a multi-line draft — is the person mid-sentence.

  `:unknown` is the honest third answer, and it is the one ADR-0008 already
  rules on: no marker on the screen (the pane is scrolled away from the box, or
  Claude Code has changed how it draws one) is a signal that is unavailable,
  and delivery goes ahead rather than going silent.
  """

  @marker "❯"

  @doc """
  Judge a `pane.read` of the main session's visible screen.

  `:empty` — the box is there and holds nothing; `:typing` — it holds a draft;
  `:unknown` — no box was found, so the screen says nothing either way.
  """
  @spec read(String.t()) :: :empty | :typing | :unknown
  def read(screen) do
    screen
    |> String.split("\n")
    |> Enum.reverse()
    |> Enum.find_value(:unknown, fn line ->
      case String.trim_leading(line) do
        @marker <> rest -> if blank?(rest), do: :empty, else: :typing
        _other -> nil
      end
    end)
  end

  # `String.trim/1` leaves the non-breaking space alone — it is not whitespace
  # to Elixir, and it is exactly what Claude Code puts after the marker.
  defp blank?(rest), do: rest |> String.replace(" ", " ") |> String.trim() == ""
end
