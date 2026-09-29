defmodule Whiska.Watch.Transcript do
  @moduledoc """
  What a mouse is doing right now, read from its own Claude Code transcript.

  ADR-0026 named this signal — "the last-tool-call excerpt from knowing what a
  mouse is doing" — and nothing had ever produced it: the hook opens SQLite and
  exits (ADR-0030), so no part of Whiska is in the room while a mouse works.
  ADR-0050 settles where it comes from instead: Claude Code writes every session
  to `~/.claude/projects/<worktree path>/<session>.jsonl` as it goes, and the
  board reads the tail of that file. Nothing is asked of the mouse, which is the
  whole point — a board that prompted a session to find out what it was doing
  would cost that session a turn (ADR-0044's lesson).

  The file is somebody else's format, so everything here is defensive: a line
  that will not parse is skipped, a half-written last line is skipped, and a
  transcript with nothing recognisable in it is `nil` rather than a guess. The
  board simply leaves that column empty.

  Only the tail is read (`@tail_bytes`). A session's transcript grows all day
  and the board reads every mouse's every two seconds.
  """

  alias Whiska.LaunchAgent

  @typedoc "The phrase a row shows: a tool call, the last thing said, or nothing."
  @type action :: {:tool, String.t()} | {:said, String.t()} | nil

  # What one column of a statusline row has room for.
  @phrase_max 60

  # Enough tail for the last few turns; a transcript runs to hundreds of KB.
  @tail_bytes 64 * 1024

  # The invisible marker a mouse ends its turn on (three U+2063, or two). It is
  # stripped before the person ever reads a message and must not become a row.
  @marker "⁣"

  @doc """
  The mouse's last action, or `nil` when its transcript says nothing.

  Options: `:user_home`, the home to look under — `Whiska.LaunchAgent.user_home/0`
  unless a test pins it.
  """
  @spec read(Path.t(), keyword()) :: action()
  def read(worktree_root, opts \\ []) do
    home = Keyword.get_lazy(opts, :user_home, &LaunchAgent.user_home/0)

    case newest_transcript(project_dir(worktree_root, home)) do
      nil -> nil
      file -> file |> tail() |> last_action(worktree_root)
    end
  end

  @doc """
  Claude Code's own folder for a working directory: every character that is not
  a letter or a digit replaced by a dash, one for one.

  Checked against a real `~/.claude/projects` on 2026-09-29 — `~/.herdr/worktrees/x`
  is recorded as `--herdr-worktrees-x`, the dot and the slash each becoming
  their own dash, so the replacement collapses nothing.
  """
  @spec project_dir(Path.t(), Path.t()) :: Path.t()
  def project_dir(worktree_root, user_home) do
    slug = String.replace(Path.expand(worktree_root), ~r/[^A-Za-z0-9]/, "-")

    Path.join([user_home, ".claude", "projects", slug])
  end

  @doc """
  The last action in a transcript's text. Pure, and total: anything it cannot
  read is `nil`.

  Walks backwards to the newest line it understands. A tool call wins over a
  sentence in the same message — a mouse that has just started a tool is doing
  that tool, whatever it said on the way in — and what the *person* typed is
  never the mouse's action.
  """
  @spec last_action(String.t(), Path.t()) :: action()
  def last_action(text, worktree_root) do
    text
    |> String.split("\n")
    |> Enum.reverse()
    |> Enum.find_value(&action_in(&1, worktree_root))
  end

  defp action_in(line, worktree_root) do
    with {:ok, %{"type" => "assistant", "message" => %{"content" => content}}} <-
           JSON.decode(line),
         true <- is_list(content) do
      tool_action(content, worktree_root) || said_action(content)
    else
      _unreadable -> nil
    end
  end

  defp tool_action(content, worktree_root) do
    content
    |> Enum.filter(&(is_map(&1) and &1["type"] == "tool_use"))
    |> List.last()
    |> case do
      nil -> nil
      %{"name" => name} = call -> {:tool, phrase(name, target(call["input"], worktree_root))}
      _nameless -> nil
    end
  end

  defp phrase(name, nil), do: cut(name)
  defp phrase(name, target), do: cut("#{name} #{target}")

  # The one thing about a call worth a column: what it is being done to. Ordered
  # by how much it says, so a Bash call reads as its command rather than as the
  # description somebody wrote for the permission prompt.
  defp target(input, worktree_root) when is_map(input) do
    cond do
      path = string(input["file_path"]) -> relative(path, worktree_root)
      command = string(input["command"]) -> first_line(command)
      pattern = string(input["pattern"]) -> pattern
      url = string(input["url"]) -> url
      description = string(input["description"]) -> description
      true -> nil
    end
  end

  defp target(_absent, _worktree_root), do: nil

  defp string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp string(_other), do: nil

  defp relative(path, worktree_root) do
    Path.relative_to(path, Path.expand(worktree_root))
  end

  defp first_line(command), do: command |> String.split("\n", parts: 2) |> hd() |> String.trim()

  defp said_action(content) do
    content
    |> Enum.filter(&(is_map(&1) and &1["type"] == "text"))
    |> Enum.map_join("\n", &to_string(&1["text"]))
    |> last_sentence()
    |> case do
      nil -> nil
      sentence -> {:said, cut(sentence)}
    end
  end

  @doc """
  The last sentence of what a mouse said, or `nil` when it said nothing a row
  could show.

  The marker line goes first: it is invisible characters on purpose and the
  person never reads it, so it must not be what the board shows either.
  """
  @spec last_sentence(String.t()) :: String.t() | nil
  def last_sentence(text) do
    text
    |> String.replace(@marker, "")
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> List.last()
    |> case do
      nil -> nil
      line -> line |> String.split(~r/(?<=[.!?])\s+/) |> List.last() |> string()
    end
  end

  defp cut(phrase) when byte_size(phrase) == 0, do: phrase

  defp cut(phrase) do
    if String.length(phrase) > @phrase_max do
      String.slice(phrase, 0, @phrase_max - 1) <> "…"
    else
      phrase
    end
  end

  defp newest_transcript(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.max_by(&mtime/1, fn -> nil end)

      {:error, _gone} ->
        nil
    end
  end

  defp mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} -> mtime
      {:error, _gone} -> 0
    end
  end

  # The tail, with the first line dropped when it may have been cut in half.
  defp tail(path) do
    with {:ok, %File.Stat{size: size}} <- File.stat(path),
         {:ok, io} <- File.open(path, [:read, :binary]) do
      try do
        from = max(size - @tail_bytes, 0)
        :file.position(io, {:bof, from})
        read_from(io, from)
      after
        File.close(io)
      end
    else
      _gone -> ""
    end
  end

  defp read_from(io, from) do
    case IO.binread(io, :eof) do
      text when is_binary(text) and from > 0 ->
        text |> String.split("\n", parts: 2) |> Enum.at(1, "")

      text when is_binary(text) ->
        text

      _empty ->
        ""
    end
  end
end
