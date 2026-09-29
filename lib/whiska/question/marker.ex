defmodule Whiska.Question.Marker do
  @moduledoc """
  Classifying a mouse's final message by the marker it wrote — and nothing else.

  ADR-0009 draws the line: no heuristics, no reading the text to guess. The
  absence of a marker is itself a classification — `unmarked`, which is
  delivered like a question. Forgetting is the loud direction, on purpose.

  ## The marker is invisible

  A mouse ends its turn with a line of invisible separators (U+2063) and
  nothing else on it: three for `done`, two for `needs-decision`. Claude Code's
  terminal renders every readable candidate verbatim — an HTML comment, a link
  reference definition, a hidden span — so the only spelling a person does not
  see in the pane is one made of characters that draw nothing. `needs-decision`
  carries its pointer as ordinary prose on the line before, which the person
  reads in the pane like any other sentence.

  The older bracket spelling — `[worktree-status: done]`, optionally behind an
  invisible prefix — is still read, so a mouse mid-flight and every message
  already stored keep classifying. Nothing writes it any more.

  ## Only the last marker line counts

  `classify/1`, `pointer/1` and `strip/1` all act on the *last* line carrying a
  marker, and leave every other line exactly as it is. A message that quotes a
  marker mid-prose — a report about this very grammar, say — keeps its words.
  """

  @invisible "⁣"
  # The closing bracket is required: a line that opens one and never closes it is
  # prose about the marker, not a marker.
  @bracket ~r/\[worktree-status:\s*([a-z-]+)\][ \t]*([^\n]*)/
  @prefixes ~r/[\x{2060}\x{2063}\x{200B}\x{FEFF}]/u

  @doc "The kind a message's marker gives it; `unmarked` when there is none."
  @spec classify(String.t()) :: String.t()
  def classify(text) when is_binary(text) do
    case marker_line(text) do
      {_index, {:quiet, kind}} -> kind
      {_index, {:bracket, word, _rest}} -> kind(word)
      nil -> "unmarked"
    end
  end

  @doc """
  The mouse's own pointer: the one line the delivery quotes.

  For the quiet marker it is the readable line the mouse wrote just above it
  ("3 questions ready, see above"), and nothing at all for a finished turn —
  its report speaks for itself. For the older bracket spelling it is what the
  mouse wrote after the marker on the same line. For an unmarked message the
  first non-empty line stands in. Never contains a newline.
  """
  @spec pointer(String.t()) :: String.t()
  def pointer(text) when is_binary(text) do
    lines = String.split(text, "\n")

    case marker_line(text) do
      {_index, {:quiet, "done"}} ->
        ""

      {index, {:quiet, _kind}} ->
        lines |> Enum.take(index) |> last_non_empty()

      {_index, {:bracket, _word, rest}} ->
        String.trim(rest)

      nil ->
        lines |> Enum.map(&String.trim/1) |> Enum.find("", &(&1 != ""))
    end
  end

  @doc """
  The message as a person reads it: the marker line gone, and every other line
  untouched.

  A quiet marker line disappears whole — it held nothing else. A bracket marker
  keeps whatever the mouse wrote after it, on its own line, since that pointer
  is content; the invisible prefix, when there is one, goes with the token. The
  stored text is never rewritten — the marker is how the owl classifies the
  turn (ADR-0009), not something to show.
  """
  @spec strip(String.t()) :: String.t()
  def strip(text) when is_binary(text) do
    case marker_line(text) do
      nil ->
        text

      {index, form} ->
        text
        |> String.split("\n")
        |> List.update_at(index, fn line -> stripped(line, form) end)
        |> Enum.reject(&(&1 == :drop))
        |> Enum.join("\n")
    end
  end

  @doc """
  The literal marker for a status, for telling a mouse what to write.

  The CLAUDE.md block quotes this rather than spelling it out again
  (`Whiska.ClaudeMd`), so what a mouse is told to write and what `classify/1`
  reads back cannot drift apart. It is invisible, so the block names it in
  words too — that is `spell/1`.
  """
  @spec render(:done | :needs_decision) :: String.t()
  def render(:done), do: String.duplicate(@invisible, 3)
  def render(:needs_decision), do: String.duplicate(@invisible, 2)

  @doc "The same marker in words, for prose that cannot show it."
  @spec spell(:done | :needs_decision) :: String.t()
  def spell(:done), do: "three U+2063 characters"
  def spell(:needs_decision), do: "two U+2063 characters"

  # The last line carrying a marker, with what it carries: `{index, form}`.
  defp marker_line(text) do
    text
    |> String.split("\n")
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.find_value(fn {line, index} ->
      case form(line) do
        nil -> nil
        form -> {index, form}
      end
    end)
  end

  defp form(line) do
    case quiet_kind(String.trim(line)) do
      nil -> bracket(line)
      kind -> {:quiet, kind}
    end
  end

  defp quiet_kind(@invisible <> @invisible <> @invisible), do: "done"
  defp quiet_kind(@invisible <> @invisible), do: "needs-decision"
  defp quiet_kind(_), do: nil

  defp bracket(line) do
    case Regex.run(@bracket, line) do
      [_, word, rest] -> {:bracket, word, rest}
      _ -> nil
    end
  end

  defp stripped(_line, {:quiet, _kind}), do: :drop

  defp stripped(line, {:bracket, _word, _rest}) do
    rest =
      line
      |> String.replace(@prefixes, "")
      |> String.replace(@bracket, "\\2")
      |> String.trim()

    if rest == "", do: :drop, else: rest
  end

  defp last_non_empty(lines) do
    lines
    |> Enum.map(&String.trim/1)
    |> Enum.reverse()
    |> Enum.find("", &(&1 != ""))
  end

  defp kind("done"), do: "done"
  defp kind("needs-decision"), do: "needs-decision"
  defp kind(_), do: "unmarked"
end
