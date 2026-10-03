defmodule Whiska.Delivery.Draft do
  @moduledoc """
  Whether the main session's prompt box is on the screen, and whether anything
  is half-typed in it.

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

  ## Finding the box

  The box is what Claude Code draws between two horizontal rules at column 0,
  at the bottom of the screen under everything else, with the prompt marker `❯`
  on the first line inside it. All of that is needed to find it, and the lowest
  frame that holds a marker is the one (ADR-0068).

  The marker alone is not the box. Claude Code draws the person's own past
  messages with it, at column 0, all the way up the scrollback, and a picker
  draws it indented in front of the highlighted row. The frame alone is not the
  box either: a rule drawn below it — by somebody's statusline — would make the
  box's own bottom rule the top of a frame around the status lines. So the
  frames are walked from the bottom until one has a prompt line in it.

  Inside the frame, Claude Code writes a non-breaking space after the marker
  and pads the line out to the box's width, so an empty box is the marker and
  nothing that is not whitespace, on any of its lines. Anything else — a word,
  a `[Pasted text #5 +8 lines]` chip, a second line under a marker on its own —
  is the person mid-sentence.
  """

  @marker "❯"
  @rule "─"

  @typedoc """
  `:empty` — the box is there and holds nothing; `:typing` — it holds a draft;
  `:no_box` — nothing on the screen is framed at all; `:unknown` — something is
  framed and no frame on the screen holds a prompt line Whiska knows.
  """
  @type t :: :empty | :typing | :no_box | :unknown

  @doc """
  Judge a `pane.read` of the main session's visible screen.
  """
  @spec read(String.t()) :: t()
  def read(screen) do
    screen
    |> String.split("\n")
    |> box()
    |> judge()
  end

  # Frames from the bottom up, until one has a prompt line in it. Running out
  # of frames having seen none is a screen Whiska cannot read; running out
  # without having seen a frame at all is a screen with no box on it.
  defp box(lines), do: lines |> Enum.reverse() |> box(false)

  defp box(below_up, framed?) do
    case Enum.drop_while(below_up, &not_rule?/1) do
      [] ->
        no_box(framed?)

      [_bottom | above] ->
        case Enum.split_while(above, &not_rule?/1) do
          {_inside, []} -> no_box(framed?)
          {inside, rest} -> prompt_line(Enum.reverse(inside), rest)
        end
    end
  end

  defp no_box(true), do: :unknown
  defp no_box(false), do: :no_box

  defp prompt_line(inside, frames_above) do
    case Enum.split_while(inside, &(not marker?(&1))) do
      {_above_it, []} -> box(frames_above, true)
      {above_it, [marker_line | below_it]} -> {above_it, marker_line, below_it}
    end
  end

  defp judge(:no_box), do: :no_box
  defp judge(:unknown), do: :unknown

  defp judge({above_it, @marker <> rest, below_it}) do
    if Enum.all?(above_it ++ below_it, &blank?/1) and blank?(rest),
      do: :empty,
      else: :typing
  end

  defp marker?(line), do: String.starts_with?(line, @marker)

  # A rule drawn inside the screen's content — a diff view's own frame, a
  # markdown horizontal rule — is indented with everything else Claude Code
  # prints. Only the box's rules start the line.
  defp rule?(line) do
    case String.trim_trailing(line) do
      "" -> false
      trimmed -> trimmed |> String.graphemes() |> Enum.all?(&(&1 == @rule))
    end
  end

  defp not_rule?(line), do: not rule?(line)

  defp blank?(text), do: String.trim(text) == ""
end
