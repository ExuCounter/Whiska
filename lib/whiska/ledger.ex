defmodule Whiska.Ledger do
  @moduledoc """
  The agent ledger every finished report ends with (ADR-0049), read from Claude
  Code's own transcripts rather than from what a hand-back says (ADR-0086).

  Read from real sessions on 2026-10-08, the hand-back is the wrong source
  three ways. Its `subagent_tokens` is the size of the agent's last model call,
  not a sum. The cold review, a forked skill (ADR-0049), hands back no usage at
  all. And the mouse's own session, usually the biggest spend, has no
  hand-back. The transcripts carry all of it: the session's file, and beside it
  a folder holding one transcript and one `meta.json` per agent it sent.

  What the transcripts say, and how each figure is read:

  - **A step is one model call.** Claude Code writes one entry per content
    block, each repeating the message's usage, so calls are counted once per
    message id.
  - **New tokens** are input plus cache writes plus output (ADR-0086). Cache
    reads are their own figure, so a line can be priced later.
  - **Average per step** is the conversation each call carried: input plus
    cache writes plus cache reads. It says whether big cache reads came from
    many steps or from a large context.
  - **A floor.** A subagent's mid-run entries are written while its reply still
    streams: their `stop_reason` is null and their output count is cut short.
    A line with any such call is a lower bound, and says so.
  - **Seconds** run from the transcript's first timestamp to its last.

  - **Effort** is read off each assistant entry, and **API errors** are the
    entries Claude Code marks `isApiErrorMessage`: a turn that died counts one.

  Agent lines cover the agents sent since the turn began — the last prompt with
  `origin.kind` `"human"`, which is also how a delivered answer arrives. The
  mouse line covers this session's whole main thread; a mouse picked up into a
  new session counts only the current one.

  `turn/2` is the same reading for one turn as it stood when it ended: the mouse
  line covers only that turn, so the owl can store turns that add up
  (ADR-0086).
  """

  @skill_marker ~r/\ABase directory for this skill: (\S+)/

  @type line :: %{
          label: String.t(),
          type: String.t() | nil,
          models: [String.t()],
          efforts: [String.t()],
          input: non_neg_integer(),
          cache_writes: non_neg_integer(),
          cache_reads: non_neg_integer(),
          output: non_neg_integer(),
          new_tokens: non_neg_integer(),
          steps: non_neg_integer(),
          avg_per_step: non_neg_integer(),
          tool_uses: non_neg_integer(),
          seconds: non_neg_integer() | nil,
          floor: boolean(),
          api_errors: non_neg_integer(),
          started_at: String.t() | nil
        }

  @type t :: %{session: Path.t(), turn_started_at: String.t() | nil, mouse: line, agents: [line]}

  @doc """
  The transcript of session `id` under `user_home`'s Claude Code projects, or
  `nil`. Searched by id across every project folder, because the folder is
  named after where the session started, which a `cd` does not change.
  """
  @spec find(String.t(), Path.t()) :: Path.t() | nil
  def find(id, user_home) do
    if id =~ ~r/\A[A-Za-z0-9_-]+\z/ do
      [user_home, ".claude", "projects", "*", id <> ".jsonl"]
      |> Path.join()
      |> Path.wildcard()
      |> List.first()
    end
  end

  @doc "The ledger of the session whose transcript is `session`."
  @spec read(Path.t()) :: t
  def read(session) do
    entries = entries(session)
    turn = turn_started_at(entries)

    %{
      session: session,
      turn_started_at: turn,
      mouse:
        entries
        |> Enum.reject(&(&1["isSidechain"] == true))
        |> tally()
        |> Map.put(:label, "mouse (whole session)"),
      agents: agents(subagents(session), turn, nil)
    }
  end

  @doc """
  The turn of `session` that had ended by `until`: what was written after it —
  the next turn, read by a late collection — is left out. The mouse line covers
  this turn alone, from the prompt that started it; agent lines are the agents
  it sent.
  """
  @spec turn(Path.t(), DateTime.t()) :: t
  def turn(session, %DateTime{} = until) do
    entries = session |> entries() |> Enum.filter(&by?(&1, until))
    turn = turn_started_at(entries)

    %{
      session: session,
      turn_started_at: turn,
      mouse:
        entries
        |> Enum.reject(&(&1["isSidechain"] == true))
        |> Enum.filter(&(turn == nil or &1["timestamp"] >= turn))
        |> tally()
        |> Map.put(:label, "mouse (this turn)"),
      agents: agents(subagents(session), turn, until)
    }
  end

  defp subagents(session), do: session |> Path.rootname() |> Path.join("subagents")

  # Timestamped at or before `until`. An entry with no time cannot be placed,
  # and none that carries usage lacks one.
  defp by?(%{"timestamp" => at}, until) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, t, _} -> DateTime.compare(t, until) != :gt
      _unreadable -> false
    end
  end

  defp by?(_untimed, _until), do: false

  defp agents(dir, turn, until) do
    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.reject(&written_before?(&1, turn))
        |> Enum.map(&agent(&1, until))
        |> Enum.filter(&(turn == nil or (&1.started_at != nil and &1.started_at >= turn)))
        |> Enum.reject(&(until != nil and &1.started_at == nil))
        |> Enum.sort_by(& &1.started_at)

      {:error, _none} ->
        []
    end
  end

  # The folder keeps every agent the session ever sent. One whose file was
  # last written before the turn began cannot have started in it, and is not
  # read at all.
  defp written_before?(_path, nil), do: false

  defp written_before?(path, turn) do
    with {:ok, started, _} <- DateTime.from_iso8601(turn),
         {:ok, %File.Stat{mtime: mtime}} <- File.stat(path, time: :posix) do
      mtime < DateTime.to_unix(started)
    else
      _unknown -> false
    end
  end

  defp agent(path, until) do
    entries = entries(path)
    entries = if until, do: Enum.filter(entries, &by?(&1, until)), else: entries
    meta = meta(Path.rootname(path) <> ".meta.json")

    entries
    |> tally()
    |> Map.merge(%{label: plain(label(meta, entries, path)), type: plain(meta["agentType"])})
  end

  # Text another agent wrote, printed one line per agent: no control character
  # or line separator may break the line or reach the terminal.
  defp plain(text) when is_binary(text),
    do:
      text
      |> String.replace(~r/[\x{0}-\x{1f}\x{7f}-\x{9f}\x{2028}\x{2029}]+/u, " ")
      |> String.trim()

  defp plain(_not_text), do: nil

  # A forked skill's meta carries no description; its opening prompt names the
  # skill's folder (ADR-0049).
  defp label(%{"description" => description}, _entries, _path) when is_binary(description),
    do: description

  defp label(_meta, entries, path) do
    with %{"message" => %{"content" => text}} when is_binary(text) <-
           Enum.find(entries, &(&1["type"] == "user")),
         [_, dir] <- Regex.run(@skill_marker, text) do
      Path.basename(dir)
    else
      _no_skill -> path |> Path.basename(".jsonl") |> String.replace_prefix("agent-", "")
    end
  end

  defp meta(path) do
    with {:ok, raw} <- read_regular(path),
         {:ok, %{} = meta} <- JSON.decode(raw) do
      meta
    else
      _unreadable -> %{}
    end
  end

  defp tally(entries) do
    calls =
      for(
        %{"type" => "assistant", "message" => %{"usage" => %{}} = message} = entry <- entries,
        message["model"] != "<synthetic>",
        do: entry
      )
      |> Enum.group_by(& &1["message"]["id"])
      |> Map.values()
      |> Enum.map(&call/1)

    tools =
      for %{"type" => "assistant", "message" => %{"content" => blocks}} <- entries,
          is_list(blocks),
          %{"type" => "tool_use", "id" => id} <- blocks,
          uniq: true,
          do: id

    sum = fn key -> calls |> Enum.map(& &1[key]) |> Enum.sum() end
    [input, writes, reads, output] = Enum.map([:input, :writes, :reads, :output], sum)
    times = for %{"timestamp" => at} when is_binary(at) <- entries, do: at

    %{
      type: nil,
      models: calls |> Enum.map(& &1.model) |> Enum.reject(&is_nil/1) |> Enum.uniq(),
      efforts: calls |> Enum.map(& &1.effort) |> Enum.reject(&is_nil/1) |> Enum.uniq(),
      input: input,
      cache_writes: writes,
      cache_reads: reads,
      output: output,
      new_tokens: input + writes + output,
      steps: length(calls),
      avg_per_step: if(calls == [], do: 0, else: round((input + writes + reads) / length(calls))),
      tool_uses: length(tools),
      seconds: seconds(times),
      floor: Enum.any?(calls, &(not &1.stopped)),
      api_errors: Enum.count(entries, &(&1["isApiErrorMessage"] == true)),
      started_at: Enum.min(times, fn -> nil end)
    }
  end

  # The entries of one call repeat its usage; the last written holds the most
  # output, and any entry with a stop reason means the count is final.
  defp call(entries) do
    messages = Enum.map(entries, & &1["message"])
    usage = messages |> Enum.map(& &1["usage"]) |> Enum.max_by(&count(&1, "output_tokens"))

    %{
      model: messages |> Enum.map(& &1["model"]) |> Enum.find(&is_binary/1) |> plain(),
      effort: entries |> Enum.map(& &1["effort"]) |> Enum.find(&is_binary/1) |> plain(),
      input: count(usage, "input_tokens"),
      writes: count(usage, "cache_creation_input_tokens"),
      reads: count(usage, "cache_read_input_tokens"),
      output: count(usage, "output_tokens"),
      stopped: Enum.any?(messages, &is_binary(&1["stop_reason"]))
    }
  end

  defp count(usage, key) do
    case usage[key] do
      n when is_integer(n) and n >= 0 -> n
      _missing -> 0
    end
  end

  # Entries are not always written in time order, so the span is earliest to
  # latest rather than first to last.
  defp seconds(times) do
    case for(at <- times, {:ok, t, _} <- [DateTime.from_iso8601(at)], do: t) do
      [] -> nil
      parsed -> DateTime.diff(Enum.max(parsed, DateTime), Enum.min(parsed, DateTime))
    end
  end

  defp turn_started_at(entries) do
    for(
      %{"type" => "user", "origin" => %{"kind" => "human"}, "timestamp" => at} <- entries,
      is_binary(at),
      do: at
    )
    |> List.last()
  end

  # A line that will not parse — a half-written last one included — is skipped.
  # Each entry keeps only what a line is counted from: tool results and the
  # text of every reply are most of a transcript's size, and none of its count.
  defp entries(path) do
    case read_regular(path) do
      {:ok, raw} ->
        for line <- String.split(raw, "\n"),
            line != "",
            {:ok, %{} = entry} <- [JSON.decode(line)],
            do: slim(entry)

      {:error, _gone} ->
        []
    end
  end

  @kept ~w(type timestamp isSidechain origin isApiErrorMessage effort)

  defp slim(entry) do
    case entry["message"] do
      %{} = message -> entry |> Map.take(@kept) |> Map.put("message", slim_message(message))
      _no_message -> Map.take(entry, @kept)
    end
  end

  defp slim_message(message) do
    message
    |> Map.take(~w(id model usage stop_reason))
    |> Map.put("content", tool_uses(message["content"]))
  end

  defp tool_uses(blocks) when is_list(blocks),
    do:
      for(%{"type" => "tool_use", "id" => id} <- blocks, do: %{"type" => "tool_use", "id" => id})

  defp tool_uses(text) when is_binary(text), do: text
  defp tool_uses(_other), do: nil

  # Ten times the largest transcript seen on 2026-10-11.
  @max_bytes 256 * 1024 * 1024

  @doc """
  Whether `path` is a transcript this module reads: a plain file under the
  size cap. A pipe or device named like one would hang the read or never end.
  """
  @spec readable?(Path.t()) :: boolean()
  def readable?(path) do
    match?({:ok, %File.Stat{type: :regular, size: size}} when size <= @max_bytes, File.stat(path))
  end

  defp read_regular(path) do
    if readable?(path), do: File.read(path), else: {:error, :not_readable}
  end

  @doc "The ledger as lines for a finished report: the agents, then the mouse."
  @spec render(t) :: String.t()
  def render(%{agents: agents, mouse: mouse}),
    do: Enum.map_join(agents ++ [mouse], "\n", &render_line/1)

  defp render_line(line) do
    [
      line.label,
      line.type,
      models(line.models),
      efforts(line.efforts),
      "new " <> if(line.floor, do: "≥", else: "") <> short(line.new_tokens),
      "reads " <> short(line.cache_reads),
      "#{line.steps} #{plural(line.steps, "step")}",
      "avg #{short(line.avg_per_step)}/step",
      "#{line.tool_uses} #{plural(line.tool_uses, "tool use")}",
      if(line.seconds, do: "#{line.seconds}s", else: "seconds unknown")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp models([]), do: "model unknown"
  defp models(models), do: Enum.join(models, "+")

  defp efforts([]), do: nil
  defp efforts(efforts), do: Enum.join(efforts, "+")

  defp plural(1, word), do: word
  defp plural(_n, word), do: word <> "s"

  defp short(n) when n < 1_000, do: Integer.to_string(n)
  defp short(n) when n < 1_000_000, do: one_place(n / 1_000) <> "k"
  defp short(n), do: one_place(n / 1_000_000) <> "M"

  defp one_place(x) do
    x |> Float.round(1) |> :erlang.float_to_binary(decimals: 1) |> String.replace_suffix(".0", "")
  end

  @doc """
  The same figures as data, for a later per-branch budget to sum. `version`
  bumps when a field changes meaning.
  """
  @spec json(t) :: String.t()
  def json(ledger) do
    JSON.encode!(%{
      version: 1,
      session: ledger.session,
      turn_started_at: ledger.turn_started_at,
      mouse: ledger.mouse,
      agents: ledger.agents
    })
  end
end
