defmodule Whiska.Report do
  @moduledoc """
  A mouse's final message as a document: one with a `## Summary` heading of its
  own, outside any code block (ADR-0089). A sniff
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

  @doc """
  The one line that says what a finished report came to: the pointer after its
  marker when it wrote one, else the first line of its `## Summary`, else the
  last line before the agent ledger it ends in; `""` when it has none.
  """
  @spec outcome(String.t()) :: String.t()
  def outcome(text) do
    case {Marker.classify(text), Marker.pointer(text)} do
      {"unmarked", _first_line} -> summary_line(text)
      {_kind, ""} -> summary_line(text)
      {_kind, pointer} -> pointer
    end
  end

  defp summary_line(text) do
    lines =
      text
      |> Marker.strip()
      |> String.split("\n")
      |> Enum.take_while(&(not ledger_heading?(&1)))

    case section(Enum.join(lines, "\n"), "## Summary") do
      body when body in [nil, ""] -> last_line(lines)
      body -> body |> String.split("\n") |> Enum.find("", &prose?/1) |> String.trim()
    end
  end

  defp ledger_heading?(line),
    do: String.trim(line, "#") |> String.trim("*") |> String.trim() == "Agent usage this session"

  defp prose?(line),
    do: String.trim(line) != "" and not String.starts_with?(String.trim(line), "```")

  defp last_line(lines),
    do: lines |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 in ["", "---"])) |> List.last("")

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
