defmodule Whiska.Transcript do
  @moduledoc """
  Claude Code's own JSONL transcript: where a session's file lives, how to read
  its tail, and whether the mouse has a subagent still out (ADR-0050, ADR-0052).

  Two readers sit on top of this. The board asks what a mouse is doing
  (`Whiska.Watch.Transcript`); the `Stop` hook asks whether the turn it was
  handed is actually over (`Whiska.Hook.Stop`). Both read a file Whiska does not
  own, in somebody else's format, so everything here is defensive: a line that
  will not parse is skipped, a half-written last line is skipped, and a file
  that is not there reads as empty rather than as an error.

  ## What "a subagent still out" looks like

  Read from a real transcript on 2026-09-29. A background `Agent` call gets its
  `tool_result` immediately — it says only that the agent was launched, and
  carries the agent's id:

      Async agent launched successfully. …
      agentId: ae96c5149391564f6 …

  The agent's report arrives later, as a user entry whose whole content is text:

      Another Claude session sent a message:
      <agent-message from="ae96c5149391564f6">
      [Subagent hand-back] …

  So a pending `tool_use` is the wrong thing to look for — every launch has a
  result within milliseconds. What is pending is the hand-back, and an id
  launched but not handed back is a subagent the session will be woken for.
  """

  # Enough tail to hold a whole turn, launches included. `Stop` fires once per
  # turn, so this is read a few times a minute rather than every two seconds.
  @tail_bytes 512 * 1024

  # The id Claude Code prints when a background Agent starts, and the id on the
  # frame its report comes back in.
  @launched ~r/^agentId: ([A-Za-z0-9_-]+)/m
  @handed_back ~r/<agent-message from="([A-Za-z0-9_-]+)">/

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
  The last `bytes` of a transcript, with the first line dropped when it may have
  been cut in half. A file that is gone or unreadable is `""`.
  """
  @spec tail(Path.t(), pos_integer()) :: String.t()
  def tail(path, bytes \\ @tail_bytes) do
    with {:ok, %File.Stat{size: size}} <- File.stat(path),
         {:ok, io} <- File.open(path, [:read, :binary]) do
      try do
        from = max(size - bytes, 0)
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

  @doc """
  Whether this transcript shows a subagent the mouse launched and has not been
  handed back. Pure, and total: anything it cannot read counts as nothing out,
  which is the direction ADR-0009 already chose — a stop that is delivered when
  it need not have been is noise, and one that is swallowed is silence.

  Only the mouse's own entries count. A subagent's entries are marked
  `isSidechain`, and what it launches is its own business, not the mouse's.
  """
  @spec subagents_in_flight?(String.t()) :: boolean()
  def subagents_in_flight?(text) do
    text
    |> String.split("\n")
    |> Enum.reduce(MapSet.new(), &account_for/2)
    |> MapSet.size()
    |> Kernel.>(0)
  end

  defp account_for(line, out) do
    case JSON.decode(line) do
      {:ok, %{"isSidechain" => true}} -> out
      {:ok, %{"message" => %{"content" => content}}} -> account_for_content(content, out)
      _unreadable -> out
    end
  end

  defp account_for_content(content, out) when is_list(content) do
    content
    |> Enum.filter(&(is_map(&1) and &1["type"] == "tool_result"))
    |> Enum.flat_map(&launched_ids(&1["content"]))
    |> Enum.into(out)
  end

  defp account_for_content(content, out) when is_binary(content) do
    if String.contains?(content, "[Subagent hand-back]") do
      @handed_back
      |> Regex.scan(content, capture: :all_but_first)
      |> List.flatten()
      |> Enum.reduce(out, &MapSet.delete(&2, &1))
    else
      out
    end
  end

  defp account_for_content(_other, out), do: out

  defp launched_ids(blocks) when is_list(blocks) do
    blocks
    |> Enum.filter(&(is_map(&1) and is_binary(&1["text"])))
    |> Enum.flat_map(
      &(@launched
        |> Regex.scan(&1["text"], capture: :all_but_first)
        |> List.flatten())
    )
  end

  defp launched_ids(text) when is_binary(text) do
    @launched |> Regex.scan(text, capture: :all_but_first) |> List.flatten()
  end

  defp launched_ids(_other), do: []
end
