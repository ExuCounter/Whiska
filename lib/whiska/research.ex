defmodule Whiska.Research do
  @moduledoc """
  The research document a finished investigation leaves for the person to review: what it
  established and its Proposed build, as Markdown at the worktree root
  (ADR-0074).

  It is the one file a sniff mouse may write (ADR-0069), and like the spec it
  is never committed: git ignores it through the main checkout's
  `.git/info/exclude` (ADR-0063). Its text rides on the turn's doorstep entry,
  and the owl keeps it per question in `.whiska/research/<id>.md`, which
  `whiska show` links.
  """

  alias Whiska.Doorstep.Entry
  alias Whiska.HouseFile
  alias Whiska.Layout

  @filename ".whiska-research.md"
  @dir ".whiska/research"

  @spec filename() :: String.t()
  def filename, do: @filename

  @doc "The exclude pattern, anchored like the spec's."
  @spec exclude_line() :: String.t()
  def exclude_line, do: "/" <> @filename

  @doc """
  Whether `path` names the research document of the worktree at `worktree_root`: that
  file and no other, and never a link, since a write through one lands
  wherever it points. Only an absolute path with no `..` in it qualifies: a
  relative one lands wherever the session stands, and `..` after a linked
  folder climbs out of wherever that folder points.
  """
  @spec target?(String.t(), Path.t()) :: boolean()
  def target?(path, worktree_root) do
    Path.type(path) == :absolute and ".." not in Path.split(path) and
      Path.basename(path) == @filename and
      Layout.canonical(Path.dirname(path)) == Layout.canonical(worktree_root) and
      not match?({:ok, %File.Stat{type: :symlink}}, File.lstat(path))
  end

  @doc "Where the research document `question_id` carried is kept, whether or not it was."
  @spec kept(Path.t(), pos_integer()) :: Path.t()
  def kept(main_checkout, question_id),
    do: Path.join([main_checkout, @dir, "#{question_id}.md"])

  @doc """
  The research document kept for `question_id`, as its path and the title its link
  shows: its first heading, else "research". Nil when none was kept.
  """
  @spec find(Path.t(), pos_integer()) :: {Path.t(), String.t()} | nil
  def find(main_checkout, question_id) do
    path = kept(main_checkout, question_id)

    with {:ok, %File.Stat{type: :regular}} <- File.lstat(path),
         {:ok, head} <- head(path) do
      {path, title(head)}
    else
      _ -> nil
    end
  end

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

  # The mouse's own words, set inside a Markdown link under the branch line:
  # nothing that could close the link, escape its bracket, or reorder the line
  # survives.
  defp title(text) do
    with [_, heading] <- Regex.run(~r/^#[ \t]+([^\n]+)$/m, text),
         title when title != "" <-
           heading
           |> String.replace_invalid("?")
           |> String.replace(~r/[\p{C}\p{Zl}\p{Zp}]/u, "?")
           |> String.replace(~r/[\[\]\\<>]/, "")
           |> String.trim() do
      title
    else
      _ -> "research"
    end
  end

  @doc "Keep the research document an entry carried, under the question it was recorded as."
  @spec keep(Path.t(), Entry.t(), pos_integer()) :: :ok | :none | {:error, term()}
  def keep(_main_checkout, %Entry{research: nil}, _question_id), do: :none

  def keep(main_checkout, %Entry{research: text}, question_id) do
    with {:ok, _path} <- HouseFile.write(main_checkout, @dir, "#{question_id}.md", text),
         do: :ok
  end
end
