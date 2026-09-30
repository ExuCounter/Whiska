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
  `tool_result` within milliseconds — it carries no result, only the agent's id:

      Async agent launched successfully. …
      agentId: ae96c5149391564f6 …

  So a pending `tool_use` is the wrong thing to look for. What is pending is the
  report, which arrives later as a user entry Claude Code stamps
  `origin: %{"kind" => "peer", "handback" => true, "from" => "<the id>"}`.

  Both ends are read structurally. A launch counts only when its `tool_result`
  answers an `Agent` call seen in the same tail, so a line of shell output that
  happens to read `agentId: …` launches nothing. A hand-back is read from
  `origin`, with the frame in the text as a fallback for a transcript that
  carries no `origin`.

  A turn the person started clears the accounting: `origin: %{"kind" => "human"}`.
  Whatever was out when they typed is theirs to have interrupted, and a mouse
  held silent by an agent that will never report is the one direction this must
  not fail in.
  """

  # Enough tail to hold a whole turn, launches included. `Stop` fires once per
  # turn, so this is read a few times a minute rather than every two seconds.
  @tail_bytes 512 * 1024

  # The session's own header and the start of its first turn; the working
  # directory is named well inside this. Counted in lines rather than bytes,
  # because one opening paste can be larger than any sensible byte window and
  # cutting the read there would answer "started nowhere" for a session that
  # plainly did. Two ceilings keep that from becoming unbounded on a hook that
  # runs per tool call: a line fatter than an entry ever needs to be is skipped
  # unparsed, and the whole search gives up after a megabyte.
  @head_lines 200
  @head_bytes 1024 * 1024
  @line_bytes 64 * 1024

  # The id Claude Code prints when a background Agent starts, and the frame its
  # report comes back in, read only from transcripts that carry no `origin`.
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
  The directory the session was started in, read from the first entry that names
  one — `nil` for a transcript that is not there, names none, or is not a plain
  file.

  Claude Code stamps each entry with the session's working directory, and that
  follows any `cd` the session runs. The first entry predates all of them, which
  is what makes this an identity rather than a position (ADR-0053).
  """
  @spec started_in(Path.t()) :: Path.t() | nil
  def started_in(path) do
    with {:ok, %File.Stat{type: :regular}} <- File.stat(path),
         {:ok, io} <- File.open(path, [:read, :binary]) do
      try do
        first_cwd(io, @head_lines, @head_bytes)
      after
        File.close(io)
      end
    else
      _unreadable -> nil
    end
  end

  defp first_cwd(_io, 0, _bytes), do: nil
  defp first_cwd(_io, _lines, bytes) when bytes <= 0, do: nil

  defp first_cwd(io, lines, bytes) do
    case IO.read(io, :line) do
      line when is_binary(line) ->
        cwd_in(line) || first_cwd(io, lines - 1, bytes - byte_size(line))

      _eof_or_error ->
        nil
    end
  end

  defp cwd_in(line) when byte_size(line) > @line_bytes, do: nil

  defp cwd_in(line) do
    case JSON.decode(line) do
      {:ok, %{"cwd" => cwd}} when is_binary(cwd) and cwd != "" -> cwd
      _other -> nil
    end
  end

  @doc """
  The last `bytes` of a transcript, with the first line dropped when it may have
  been cut in half. Anything that is not a plain file — gone, a directory, a
  pipe with nobody writing to it — is `""`.
  """
  @spec tail(Path.t(), pos_integer()) :: String.t()
  def tail(path, bytes \\ @tail_bytes) do
    with {:ok, %File.Stat{type: :regular, size: size}} <- File.stat(path),
         {:ok, io} <- File.open(path, [:read, :binary]) do
      try do
        from = max(size - bytes, 0)
        :file.position(io, {:bof, from})
        read_from(io, from)
      after
        File.close(io)
      end
    else
      _unreadable -> ""
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
    |> Enum.reduce(%{agent_calls: MapSet.new(), out: MapSet.new()}, &account_for/2)
    |> Map.fetch!(:out)
    |> Enum.any?()
  end

  defp account_for(line, state) do
    case JSON.decode(line) do
      {:ok, %{"isSidechain" => true}} -> state
      {:ok, entry} when is_map(entry) -> account_for_entry(entry, state)
      _unreadable -> state
    end
  end

  defp account_for_entry(%{"origin" => %{"kind" => "human"}}, state) do
    %{state | out: MapSet.new()}
  end

  defp account_for_entry(%{"origin" => %{"handback" => true, "from" => id}}, state)
       when is_binary(id) do
    %{state | out: MapSet.delete(state.out, id)}
  end

  defp account_for_entry(%{"message" => %{"content" => content}}, state) do
    account_for_content(content, state)
  end

  defp account_for_entry(_other, state), do: state

  defp account_for_content(content, state) when is_list(content) do
    Enum.reduce(content, state, &account_for_block/2)
  end

  defp account_for_content(content, state) when is_binary(content) do
    if String.contains?(content, "[Subagent hand-back]") do
      %{state | out: MapSet.difference(state.out, ids(@handed_back, content))}
    else
      state
    end
  end

  defp account_for_content(_other, state), do: state

  defp account_for_block(%{"type" => "tool_use", "name" => "Agent", "id" => id}, state)
       when is_binary(id) do
    %{state | agent_calls: MapSet.put(state.agent_calls, id)}
  end

  defp account_for_block(%{"type" => "tool_result", "tool_use_id" => id} = block, state)
       when is_binary(id) do
    if MapSet.member?(state.agent_calls, id) do
      %{state | out: MapSet.union(state.out, ids(@launched, text_of(block["content"])))}
    else
      state
    end
  end

  defp account_for_block(_other, state), do: state

  defp text_of(blocks) when is_list(blocks) do
    blocks
    |> Enum.filter(&(is_map(&1) and is_binary(&1["text"])))
    |> Enum.map_join("\n", & &1["text"])
  end

  defp text_of(text) when is_binary(text), do: text
  defp text_of(_other), do: ""

  defp ids(pattern, text) do
    pattern
    |> Regex.scan(text, capture: :all_but_first)
    |> List.flatten()
    |> MapSet.new()
  end
end
