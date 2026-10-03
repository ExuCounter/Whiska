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
  happens to read `agentId: …` launches nothing.

  A hand-back is read three ways, because it arrives in three shapes (all read
  from real transcripts on 2026-09-30, where the third silenced a mouse for four
  hours): the `origin` stamp `%{"handback" => true, "from" => id}`; the
  `<agent-message from="…">` frame; and the `<task-notification>` frame, whose id
  sits in `<task-id>`. The two frames are not a fallback for a missing stamp — the
  commonest shape of all carries `origin: %{"kind" => "task-notification"}` and
  says which agent only in its frame.

  A report that lands while the mouse is busy is *queued*, and Claude Code records
  the queued copy as an `attachment` entry, with the frame in `attachment.prompt`
  and the stamp — when there is one — on the attachment rather than the entry. It
  writes no `user` entry for that report at all, so an `attachment` is read exactly
  as a `user` entry is.

  A turn the person started clears the accounting: `origin: %{"kind" => "human"}`,
  on the entry or on its attachment. Whatever was out when they typed is theirs
  to have interrupted, and a mouse held silent by an agent that will never
  report is the one direction this must not fail in.

  A launch older than half an hour is the backstop under that
  (ADR-0052 named it): an agent that has not reported in that long is not coming
  back, and a reviewer that really is still running costs one delivered progress
  note rather than a mouse nobody hears from.
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

  # Nothing Claude Code wrote started before this; a smaller number is some
  # other field, not a creation time (GNU `stat -f %B` is a block size).
  @plausible_from 1_000_000_000

  # A launch this old is abandoned, not pending. Long enough that no reviewer
  # this repo runs comes near it, short enough that a lost hand-back costs one
  # quiet stop rather than a whole night of them. A repo that names a `security:`
  # scan under its own `## Finish` heading (ADR-0054) can sit inside step 3 for
  # tens of minutes, which is the one sanctioned way to approach this bound.
  @stale_after_seconds 30 * 60

  # The id Claude Code prints when a background Agent starts, and the two frames
  # a report names its own agent in.
  @launched ~r/^agentId: ([A-Za-z0-9_-]+)/m
  @handed_back ~r/<agent-message from="([A-Za-z0-9_-]+)">/
  @notified ~r|<task-notification>\s*<task-id>([A-Za-z0-9_-]+)</task-id>|

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

  @doc """
  When the session began: the moment its transcript file was created.

  What `whiska doctor` compares the hook wiring against — Claude Code reads
  `settings.json` once, at startup, so a session older than its own wiring is
  running the wiring from before.

  Deliberately not the first timestamp *inside* the file. A resumed session is
  a new process that read `settings.json` afresh, and Claude Code copies its
  predecessor's entries into the new transcript verbatim, timestamps and all —
  so the entries say when the first session began. Read from a real
  `~/.claude/projects` on 2026-10-02: of 264 transcripts, two were resumes
  whose first entry predated their own file by up to 64 minutes, and the
  session that had just been restarted would have been reported as the stale
  one. Only the file itself says when this session started.

  `birthtime` is there for tests and gives the creation time in seconds, or
  `nil`; anything unreadable — no birth time on this filesystem, no `stat`, not
  a plain file — is `nil`, which the doctor reports as unchecked rather than
  guessing at.
  """
  @spec started_at(Path.t(), (Path.t() -> String.t() | nil)) :: DateTime.t() | nil
  def started_at(path, birthtime \\ &birthtime/1) do
    with {:ok, %File.Stat{type: :regular}} <- File.stat(path),
         seconds when is_binary(seconds) <- birthtime.(path),
         {at, ""} <- Integer.parse(String.trim(seconds)),
         true <- at >= @plausible_from do
      DateTime.from_unix!(at)
    else
      _unknown -> nil
    end
  end

  # macOS spells the birth time `-f %B` and GNU coreutils spells it `-c %W`.
  # Neither is a safe default: on GNU, `-f %B` is the filesystem's block size
  # and exits 0, so its answer is checked for being a plausible timestamp at
  # all rather than trusted for having parsed.
  defp birthtime(path) do
    Enum.find_value([["-f", "%B"], ["-c", "%W"]], fn flags ->
      case System.cmd("stat", flags ++ [path], stderr_to_stdout: true) do
        {out, 0} ->
          case Integer.parse(String.trim(out)) do
            {at, ""} when at >= @plausible_from -> String.trim(out)
            _implausible -> nil
          end

        _no_answer ->
          nil
      end
    end)
  rescue
    ErlangError -> nil
  end

  # The session's own header and the start of its first turn, read under the
  # three ceilings above.
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
  handed back. Pure — `now` is passed in — and total: anything it cannot read
  counts as nothing out, which is the direction ADR-0009 already chose — a stop
  that is delivered when it need not have been is noise, and one that is
  swallowed is silence.

  Only the mouse's own entries count. A subagent's entries are marked
  `isSidechain`, and what it launches is its own business, not the mouse's.
  """
  @spec subagents_in_flight?(String.t()) :: boolean()
  @spec subagents_in_flight?(String.t(), DateTime.t()) :: boolean()
  def subagents_in_flight?(text, now \\ DateTime.utc_now()) do
    text
    |> String.split("\n")
    |> Enum.reduce(%{agent_calls: MapSet.new(), out: %{}}, &account_for/2)
    |> Map.fetch!(:out)
    |> Enum.any?(fn {_id, launched_at} -> not abandoned?(launched_at, now) end)
  end

  # A launch whose entry carries no readable timestamp cannot be aged, so it
  # holds the turn exactly as it did before — the frames above are what clears
  # it. Every entry a real transcript writes carries one.
  defp abandoned?(nil, _now), do: false
  defp abandoned?(launched_at, now), do: DateTime.diff(now, launched_at) > @stale_after_seconds

  defp account_for(line, state) do
    case JSON.decode(line) do
      {:ok, %{"isSidechain" => true}} -> state
      {:ok, entry} when is_map(entry) -> account_for_entry(entry, state)
      _unreadable -> state
    end
  end

  defp account_for_entry(entry, state) do
    case origin(entry) do
      %{"kind" => "human"} ->
        %{state | out: %{}}

      %{"handback" => true, "from" => id} when is_binary(id) ->
        %{state | out: Map.delete(state.out, id)}

      _no_stamp ->
        entry |> account_for_frames(state) |> account_for_blocks(entry)
    end
  end

  # The `origin` stamp sits on the entry, or — when the report was queued
  # because the mouse was busy — on the attachment that recorded it.
  defp origin(%{"origin" => %{} = origin}), do: origin
  defp origin(%{"attachment" => %{"origin" => %{} = origin}}), do: origin
  defp origin(_unstamped), do: %{}

  # Frames are read only from what the mouse was handed. An assistant message
  # that happens to quote one is the mouse's own words about a report, not the
  # report.
  defp account_for_frames(%{"type" => type} = entry, state)
       when type in ["user", "attachment"] do
    text = Enum.join([prompt_of(entry), said_in(entry)], "\n")

    state
    |> drop(ids(@notified, text))
    |> drop_framed_handback(text)
  end

  defp account_for_frames(_other, state), do: state

  defp drop_framed_handback(state, text) do
    if String.contains?(text, "[Subagent hand-back]"),
      do: drop(state, ids(@handed_back, text)),
      else: state
  end

  defp drop(state, ids), do: %{state | out: Map.drop(state.out, MapSet.to_list(ids))}

  defp prompt_of(%{"attachment" => %{"prompt" => prompt}}) when is_binary(prompt), do: prompt
  defp prompt_of(_no_attachment), do: ""

  defp said_in(%{"message" => %{"content" => content}}) when is_binary(content), do: content

  defp said_in(%{"message" => %{"content" => content}}) when is_list(content),
    do: text_of(content)

  defp said_in(_no_message), do: ""

  defp account_for_blocks(state, %{"message" => %{"content" => content}} = entry)
       when is_list(content) do
    launched_at = stamp(entry)

    Enum.reduce(content, state, &account_for_block(&1, &2, launched_at))
  end

  defp account_for_blocks(state, _other), do: state

  defp stamp(%{"timestamp" => timestamp}) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, at, _offset} -> at
      _unreadable -> nil
    end
  end

  defp stamp(_unstamped), do: nil

  defp account_for_block(%{"type" => "tool_use", "name" => "Agent", "id" => id}, state, _at)
       when is_binary(id) do
    %{state | agent_calls: MapSet.put(state.agent_calls, id)}
  end

  defp account_for_block(%{"type" => "tool_result", "tool_use_id" => id} = block, state, at)
       when is_binary(id) do
    if MapSet.member?(state.agent_calls, id) do
      launched = @launched |> ids(text_of(block["content"])) |> Map.new(&{&1, at})

      %{state | out: Map.merge(state.out, launched)}
    else
      state
    end
  end

  defp account_for_block(_other, state, _at), do: state

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
