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

  @marker ~r/\[worktree-status:\s*([a-z-]+)\]?[ \t]*([^\n]*)/

  @doc "The kind a message's marker gives it; `unmarked` when there is none."
  @spec classify(String.t()) :: String.t()
  def classify(text) when is_binary(text) do
    case Regex.scan(@marker, text) do
      [] -> "unmarked"
      matches -> matches |> List.last() |> Enum.at(1) |> kind()
    end
  end

  @doc """
  The mouse's own pointer: what it wrote after its marker on the same line
  ("3 questions ready, see above"). For an unmarked message, the first
  non-empty line stands in. Never contains a newline.
  """
  @spec pointer(String.t()) :: String.t()
  def pointer(text) when is_binary(text) do
    case Regex.scan(@marker, text) do
      [] ->
        text
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.find("", &(&1 != ""))

      matches ->
        matches |> List.last() |> Enum.at(2, "") |> String.trim()
    end
  end

  @doc """
  The literal marker for a status, for telling a mouse what to write.

  The CLAUDE.md block quotes this rather than spelling it out again
  (`Whiska.ClaudeMd`), so what a mouse is told to write and what `classify/1`
  reads back cannot drift apart.
  """
  @spec render(:done | :needs_decision) :: String.t()
  def render(:done), do: "[worktree-status: done]"
  def render(:needs_decision), do: "[worktree-status: needs-decision]"

  defp kind("done"), do: "done"
  defp kind("needs-decision"), do: "needs-decision"
  defp kind(_), do: "unmarked"
end
