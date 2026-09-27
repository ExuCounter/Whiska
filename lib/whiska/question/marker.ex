defmodule Whiska.Question.Marker do
  @moduledoc """
  Classifying a mouse's final message by the marker it wrote — and nothing else.

  ADR-0009 draws the line: no heuristics, no reading the text to guess. The
  marker is `[worktree-status: done]` or `[worktree-status: needs-decision]`,
  and its absence is itself a classification — `unmarked`, which is delivered
  like a question. Forgetting is the loud direction, on purpose.

  The marker may be prefixed with an invisible character so it never shows when
  a person reads the transcript. That prefix is optional here: it is a courtesy
  to the reader, not part of the marker's meaning, and a mouse that drops it
  must not be misread as having said nothing.
  """

  @doc "The kind a message's marker gives it; `unmarked` when there is none."
  @spec classify(String.t()) :: String.t()
  def classify(text) when is_binary(text) do
    case Regex.scan(~r/\[worktree-status:\s*([a-z-]+)/, text) do
      [] -> "unmarked"
      matches -> matches |> List.last() |> Enum.at(1) |> kind()
    end
  end

  defp kind("done"), do: "done"
  defp kind("needs-decision"), do: "needs-decision"
  defp kind(_), do: "unmarked"
end
