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
  frame that holds a marker is the one (ADR-0047).

  The marker alone is not the box. Claude Code draws the person's own past
  messages with it, at column 0, all the way up the scrollback, and a picker
  draws it indented in front of the highlighted row. The frame alone is not the
  box either: a rule drawn below it — by somebody's statusline — would make the
  box's own bottom rule the top of a frame around the status lines. So the
  frames are walked from the bottom until one has a prompt line in it.

  Inside the frame, Claude Code writes a non-breaking space after the marker
  and pads the line out to the box's width, so an empty box is the marker and
  nothing that is not whitespace or faint, on any of its lines. Anything else —
  a word, a `[Pasted text #5 +8 lines]` chip, a second line under a marker on
  its own — is the person mid-sentence.

  ## Faint text is Claude Code's, not the person's

  An empty box is not always blank. After a reply Claude Code offers the next
  prompt as faint text in it (`ESC[2m`, SGR 2), and a fresh session shows a
  `Try "…"` placeholder the same way; the cursor sits before either and nothing
  has been typed. What the person types, pastes chips included, is drawn with
  no style at all. So the screen is read with its styling (`--format ansi`),
  and only text that is not faint counts.

  Faint is a style, not a colour, so a theme change does not move it. Any style
  this does not recognise — a ghost drawn in a grey instead, an escape that is
  not a style — counts as text, and text holds. A wrong reading is a held
  question, never a line typed into a draft (ADR-0047).
  """

  @marker "❯"
  @rule "─"
  @style ~r/\e\[([0-9;]*)m/
  @style_only ~r/\A\e\[([0-9;]*)m\z/
  @escape ~r/\e(?:\[[0-9;:<=>?]*[ -\/]*[@-~]|\][^\a\e]*(?:\a|\e\\)?|[@-Z\\-_]?)/

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
    |> unstyle()
    |> box()
    |> judge()
  end

  @doc """
  Whether a line may be typed into a box read as `reading`, for delivery and
  pickup alike — both type into a session's box, so both answer here and
  cannot drift apart.

  A draft holds (ADR-0047). No box holds, because there is nowhere for the
  line to land (ADR-0047). An empty box goes, and so does a frame Whiska cannot
  read, which is ADR-0008's unavailable signal.
  """
  @spec hold(t()) :: {:hold, :typing | :no_box} | :go
  def hold(reading) when reading in [:typing, :no_box], do: {:hold, reading}
  def hold(reading) when reading in [:empty, :unknown], do: :go

  # Each line as `{plain, unfaint}`: everything printed on it with the escapes
  # taken out, and only what is not faint with every escape but a style left
  # in. The frame is found in the first, the box judged on the second. Each
  # line starts unstyled, because herdr closes every styled line.
  defp unstyle(lines), do: Enum.map(lines, &unstyle_line/1)

  defp unstyle_line(line) do
    {plain, unfaint, _faint?} =
      @style
      |> Regex.split(line, include_captures: true)
      |> Enum.reduce({"", "", false}, fn piece, {plain, unfaint, faint?} ->
        case Regex.run(@style_only, piece) do
          [_, params] ->
            {plain, unfaint, faint_after(String.split(params, ";"), faint?)}

          nil ->
            {plain <> Regex.replace(@escape, piece, ""), unfaint <> unfaint(piece, faint?),
             faint?}
        end
      end)

    {String.trim_trailing(plain, "\r"), String.trim_trailing(unfaint, "\r")}
  end

  # Faint text drops out; an escape that is not a style never does, faint or
  # not, because Whiska cannot say what it drew.
  defp unfaint(piece, faint?) do
    if faint? and not String.contains?(piece, "\e"), do: "", else: piece
  end

  # SGR parameters, left to right. A colour's own numbers are skipped so that
  # the `2` in `38;2;r;g;b` is not read as faint. Any other style — bold,
  # inverse, a colour cut short — is one Whiska cannot vouch for, so what
  # follows it counts as text.
  defp faint_after([], faint?), do: faint?

  defp faint_after([param | rest], faint?) do
    cond do
      String.trim_leading(param, "0") in ["", "22"] -> faint_after(rest, false)
      param == "2" -> faint_after(rest, true)
      param in ["38", "48", "58"] -> after_colour(rest, faint?)
      true -> false
    end
  end

  defp after_colour(["5", _ | rest], faint?), do: faint_after(rest, faint?)
  defp after_colour(["2", _, _, _ | rest], faint?), do: faint_after(rest, faint?)
  defp after_colour(_cut_short, _), do: false

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

  # Judged on what is not faint. The marker comes off the front when it is
  # there; drawn faint, it was never in the unfaint text to begin with.
  defp judge({above_it, {_, marker_line}, below_it}) do
    box = [String.replace_prefix(marker_line, @marker, "") | above_it ++ below_it]

    if Enum.all?(box, &blank?/1), do: :empty, else: :typing
  end

  defp marker?({plain, _}), do: String.starts_with?(plain, @marker)

  # A rule drawn inside the screen's content — a diff view's own frame, a
  # markdown horizontal rule — is indented with everything else Claude Code
  # prints. Only the box's rules start the line.
  defp rule?({plain, _}) do
    case String.trim_trailing(plain) do
      "" -> false
      trimmed -> trimmed |> String.graphemes() |> Enum.all?(&(&1 == @rule))
    end
  end

  defp not_rule?(line), do: not rule?(line)

  defp blank?({_, unfaint}), do: blank?(unfaint)
  defp blank?(text), do: String.trim(text) == ""
end
