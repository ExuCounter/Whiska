defmodule Whiska.Report do
  @moduledoc """
  A mouse's final message as a document: one with a `## Summary` heading of its
  own, outside any code block (ADR-next-the-report-is-a-document). A sniff
  mouse's is its research document; a build mouse's is its report. Whiska keeps
  it whole, beside the spec, and `whiska show` prints its summary, under the
  link to the rest.
  """

  alias Whiska.Question.Marker

  @spec document?(String.t()) :: boolean()
  def document?(text), do: summary(text) != nil

  @doc """
  The `## Summary` section, and under it the first line of `## What to change`
  when there is one; nil for a message that is not a document, or whose Summary
  is empty.
  """
  @spec summary(String.t()) :: String.t() | nil
  def summary(text) do
    case {section(text, "## Summary"), section(text, "## What to change")} do
      {summary, _change} when summary in [nil, ""] -> nil
      {summary, change} when change in [nil, ""] -> "## Summary\n" <> summary
      {summary, change} -> "## Summary\n#{summary}\n\n## What to change\n#{first_line(change)}"
    end
  end

  @doc "The document as Whiska keeps it: the marker line gone, one newline at the end."
  @spec text(String.t()) :: String.t()
  def text(message), do: (message |> Marker.strip() |> String.trim_trailing()) <> "\n"

  defp section(text, heading) do
    lines = text |> String.split("\n") |> in_code_block()

    case Enum.drop_while(lines, &(not heading?(&1, heading))) do
      [] ->
        nil

      [_heading | rest] ->
        rest
        |> Enum.take_while(&(not heading?(&1)))
        |> Enum.map_join("\n", &elem(&1, 0))
        |> String.trim()
    end
  end

  defp heading?({line, code?}, heading), do: not code? and String.trim_trailing(line) == heading
  defp heading?({line, code?}), do: not code? and Regex.match?(~r/^##?[ \t]/, line)

  # Each line, with whether it is part of a fenced code block, fences included.
  defp in_code_block(lines) do
    {tagged, _open?} =
      Enum.map_reduce(lines, false, fn line, open? ->
        if String.starts_with?(String.trim_leading(line), "```"),
          do: {{line, true}, not open?},
          else: {{line, open?}, open?}
      end)

    tagged
  end

  defp first_line(section), do: section |> String.split("\n") |> hd()
end
