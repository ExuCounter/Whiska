defmodule Whiska.Report do
  @moduledoc """
  A mouse's final message as a document: one with a `## Summary` heading of its
  own (ADR-next-the-report-is-a-document). A sniff mouse's is its research
  document; a build mouse's is its report. Whiska keeps it whole, beside the
  spec, and `whiska show` prints its summary, under the link to the rest.
  """

  alias Whiska.Question.Marker

  @summary ~r/^## Summary[ \t]*$/m
  @what_to_change ~r/^## What to change[ \t]*$/m

  @spec document?(String.t()) :: boolean()
  def document?(text), do: Regex.match?(@summary, text)

  @doc """
  The `## Summary` section, and under it the first line of `## What to change`
  when there is one; nil for a message that is not a document.
  """
  @spec summary(String.t()) :: String.t() | nil
  def summary(text) do
    with summary when summary != nil <- section(text, @summary) do
      case section(text, @what_to_change) do
        change when change in [nil, ""] -> "## Summary\n" <> summary
        change -> "## Summary\n#{summary}\n\n## What to change\n#{first_line(change)}"
      end
    end
  end

  @doc "The document as Whiska keeps it: the marker line gone, one newline at the end."
  @spec text(String.t()) :: String.t()
  def text(message), do: (message |> Marker.strip() |> String.trim_trailing()) <> "\n"

  defp section(text, heading) do
    case Regex.split(heading, text, parts: 2) do
      [_before, rest] -> rest |> until_next_heading() |> String.trim()
      [_none] -> nil
    end
  end

  defp until_next_heading(text) do
    case Regex.split(~r/^##?[ \t]/m, text, parts: 2) do
      [section | _] -> section
    end
  end

  defp first_line(section), do: section |> String.split("\n") |> hd()
end
