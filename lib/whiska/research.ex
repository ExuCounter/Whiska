defmodule Whiska.Research do
  @moduledoc """
  The research document a finished investigation leaves for the person to
  review: what it established and what to change (ADR-0074). A sniff mouse's is
  its final message (ADR-0089); a build mouse fixing a
  bug writes one as Markdown at the worktree root, and like the spec it is
  never committed: git ignores it through the main checkout's
  `.git/info/exclude` (ADR-0063).

  Either way its text rides on the turn's doorstep entry, and the owl keeps it
  once per branch beside the kept spec, overwritten each round, so every
  question's link opens the latest (`Whiska.SpecArchive`). A question kept
  before that has its own copy in `.whiska/research/<id>.md`.
  """

  alias Whiska.Schema.Mouse
  alias Whiska.Schema.Question
  alias Whiska.SpecArchive

  @filename ".whiska-research.md"
  @dir ".whiska/research"

  @spec filename() :: String.t()
  def filename, do: @filename

  @doc "The exclude pattern, anchored like the spec's."
  @spec exclude_line() :: String.t()
  def exclude_line, do: "/" <> @filename

  @doc """
  The research document kept for the branch `question` was asked from, as its
  path and the title its link shows: its first heading, else "research". Nil
  when none was kept.
  """
  @spec find(Path.t(), Question.t(), Mouse.t() | nil) :: {Path.t(), String.t()} | nil
  def find(main_checkout, %Question{id: id}, mouse) do
    path =
      kept(main_checkout, mouse) || Path.join([main_checkout, @dir, "#{id}.md"])

    document(path, "research")
  end

  @doc """
  A document to link for review, as its path and the title its first `# `
  heading gives it, or `fallback` with none; nil for anything but a plain
  file, so a link at another file is never offered as the document.
  """
  @spec document(Path.t(), String.t()) :: {Path.t(), String.t()} | nil
  def document(path, fallback) do
    with {:ok, %File.Stat{type: :regular}} <- File.lstat(path),
         {:ok, head} <- head(path) do
      {path, title(head, fallback)}
    else
      _ -> nil
    end
  end

  defp kept(main_checkout, %Mouse{mouse_id: mouse_id, branch: branch}) when is_binary(branch),
    do: SpecArchive.research(main_checkout, mouse_id, branch)

  defp kept(_main_checkout, _mouse), do: nil

  # The title is near the top; a whole research document need not be read for it.
  @head_bytes 4096

  defp head(path) do
    with {:ok, file} <- File.open(path, [:read, :binary]) do
      try do
        case IO.binread(file, @head_bytes) do
          data when is_binary(data) -> {:ok, data}
          :eof -> {:ok, ""}
          error -> error
        end
      after
        File.close(file)
      end
    end
  end

  # The mouse's own words, kept plain: nothing that could close a Markdown
  # link, escape its bracket, or reorder a line survives.
  defp title(text, fallback) do
    with [_, heading] <- Regex.run(~r/^#[ \t]+([^\n]+)$/m, text),
         title when title != "" <-
           heading
           |> String.replace_invalid("?")
           |> String.replace(~r/[\p{C}\p{Zl}\p{Zp}]/u, "?")
           |> String.replace(~r/[\[\]\\<>]/, "")
           |> String.trim() do
      title
    else
      _ -> fallback
    end
  end
end
