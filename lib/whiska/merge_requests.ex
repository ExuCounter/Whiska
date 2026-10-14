defmodule Whiska.MergeRequests do
  @moduledoc """
  What the owl reads of each recorded merge request on its forge, and what it
  makes of each read (ADR-0087).

  `read/3` asks the forge: the merge request, and its discussions only when
  its note count or update time moved. `next/4` is the whole judgment and
  touches nothing: the last read and this one give the row to keep and what
  happened.

  **What counts as activity.** A comment counts when it is newer than the
  cursor, is not a system note, is not the signed-in account's own, and its
  author is a member of the project. A failed pipeline counts once, and only
  when it ran on the merge request's current head. Nothing already there at
  the first read counts.

  **A read that fails is unread, never an answer.** It keeps what was last
  read, is said once, and backs off up to 15 minutes, never sooner than the
  forge's retry time. A 404 is the merge request gone only after three reads in
  a row, and only while the project itself still reads.
  """

  alias Whiska.Forge
  alias Whiska.Schema.MergeRequestRead
  alias Whiska.Schema.Mouse
  alias Whiska.Storage

  @gone_after 3
  @longest_wait_ms 900_000

  @type comment :: %{id: pos_integer(), author: String.t()}

  @type seen :: %{
          snapshot: Forge.snapshot(),
          threads_open: non_neg_integer() | nil,
          max_note_id: pos_integer() | nil,
          new_comments: [comment()]
        }

  @type result ::
          {:ok, seen()} | {:missing, true} | {:unknown, term(), pos_integer() | nil}

  @type event ::
          {:would_wake,
           %{comments: non_neg_integer(), authors: [String.t()], failed_on: String.t() | nil}}
          | :merged
          | :closed
          | :gone
          | :reopened
          | {:unreadable, term()}
          | :readable_again

  @type context :: %{
          cwd: Path.t(),
          timeout_ms: pos_integer(),
          tools: %{String.t() => Path.t()},
          me: %{String.t() => %{id: pos_integer(), username: String.t()}},
          members: %{{String.t(), String.t(), pos_integer()} => boolean()}
        }

  @doc """
  What a read runs with, from `cwd`. `tools` names a tool's path where it is
  not the one installed. The signed-in account and project membership are
  remembered in it from one read to the next.
  """
  @spec context(Path.t(), pos_integer(), %{String.t() => Path.t()}) :: context()
  def context(cwd, timeout_ms, tools \\ %{}),
    do: %{cwd: cwd, timeout_ms: timeout_ms, tools: tools, me: %{}, members: %{}}

  @doc """
  Every merge request the owl reads, with the last read of it: a current
  mouse's, whose link a forge reads and whose branch has not landed since it
  was recorded. A dropped branch's is read until it reads anything but open.
  """
  @spec watched() :: [{Mouse.t(), MergeRequestRead.t() | nil}]
  def watched do
    reads = reads()

    for mouse <- Storage.current_mice(),
        Mouse.merge_request_waiting?(mouse),
        {:ok, ref} <- [Forge.for_url(mouse.merge_request_url)],
        Forge.reads?(ref),
        row <- [reads[mouse.mouse_id]],
        is_nil(mouse.removed_at) or still_open?(row, ref.url),
        do: {mouse, row}
  end

  defp still_open?(%MergeRequestRead{url: url, state: state}, url), do: state in [nil, "open"]
  defp still_open?(_never_read, _url), do: true

  @doc "Every row, by mouse."
  @spec reads() :: %{String.t() => MergeRequestRead.t()}
  def reads, do: Storage.merge_request_reads()

  @doc "Write what `next/4` gave over the mouse's row, or as its first."
  @spec save(map()) :: :ok | {:error, term()}
  def save(attrs) do
    case Storage.save_merge_request_read(attrs) do
      {:ok, _row} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Read `mouse`'s merge request on its forge, against `row`, the last read."
  @spec read(Mouse.t(), MergeRequestRead.t() | nil, context()) :: {result(), context()}
  def read(%Mouse{merge_request_url: url}, row, context) do
    {:ok, ref} = Forge.for_url(url)
    run = run(ref, context)
    prior = prior(row, ref.url)

    case ref.forge.merge_request(ref, run) do
      {:ok, snapshot} ->
        if is_nil(prior) or is_nil(prior.seen_note_id) or moved?(prior, snapshot),
          do: with_notes(ref, run, snapshot, prior, context),
          else: {{:ok, unread_notes(snapshot)}, context}

      :missing ->
        {missing(ref, run), context}

      unknown ->
        {unknown, context}
    end
  end

  defp run(ref, context) do
    tool = ref.forge.tool()

    %{
      tool: Map.get_lazy(context.tools, tool, fn -> Forge.CLI.find(tool) end),
      cwd: context.cwd,
      timeout_ms: context.timeout_ms
    }
  end

  defp prior(%MergeRequestRead{url: url} = row, url), do: row
  defp prior(_none_or_another_link, _url), do: nil

  defp moved?(prior, snapshot),
    do: prior.notes_count != snapshot.notes_count or prior.forge_updated_at != snapshot.updated_at

  defp unread_notes(snapshot),
    do: %{snapshot: snapshot, threads_open: nil, max_note_id: nil, new_comments: []}

  defp with_notes(ref, run, snapshot, prior, context) do
    with {:ok, %{threads_open: open, notes: notes}} <- ref.forge.notes(ref, run),
         {:ok, new, context} <- new_comments(ref, run, notes, prior, context) do
      max_id = notes |> Enum.map(& &1.id) |> Enum.max(fn -> nil end)

      {{:ok, %{snapshot: snapshot, threads_open: open, max_note_id: max_id, new_comments: new}},
       context}
    else
      {:unknown, _reason, _retry} = unknown -> {unknown, context}
      {{:unknown, _reason, _retry} = unknown, context} -> {unknown, context}
      :missing -> {missing(ref, run), context}
    end
  end

  defp new_comments(_ref, _run, _notes, prior, context)
       when is_nil(prior) or is_nil(prior.seen_note_id),
       do: {:ok, [], context}

  defp new_comments(ref, run, notes, prior, context) do
    case Enum.filter(notes, &(&1.id > prior.seen_note_id and not &1.system?)) do
      [] ->
        {:ok, [], context}

      candidates ->
        with {:ok, me, context} <- me(ref, run, context) do
          candidates
          |> Enum.reject(&(&1.author_id == me.id))
          |> members_only(ref, run, context)
        end
    end
  end

  defp me(ref, run, context) do
    with :error <- Map.fetch(context.me, ref.host) do
      case ref.forge.me(ref, run) do
        {:ok, me} -> {:ok, me, put_in(context, [:me, ref.host], me)}
        :missing -> {{:unknown, :no_account, nil}, context}
        unknown -> {unknown, context}
      end
    else
      {:ok, me} -> {:ok, me, context}
    end
  end

  defp members_only(notes, ref, run, context) do
    notes
    |> Enum.map(& &1.author_id)
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, context}, fn author_id, {:ok, context} ->
      key = {ref.host, ref.project, author_id}

      if Map.has_key?(context.members, key) do
        {:cont, {:ok, context}}
      else
        case ref.forge.member?(ref, author_id, run) do
          {:ok, member?} -> {:cont, {:ok, put_in(context, [:members, key], member?)}}
          unknown -> {:halt, {unknown, context}}
        end
      end
    end)
    |> case do
      {:ok, context} ->
        kept = Enum.filter(notes, &context.members[{ref.host, ref.project, &1.author_id}])
        {:ok, Enum.map(kept, &%{id: &1.id, author: &1.author}), context}

      {unknown, context} ->
        {unknown, context}
    end
  end

  defp missing(ref, run) do
    case ref.forge.project_readable?(ref, run) do
      {:ok, true} -> {:missing, true}
      {:ok, false} -> {:unknown, :project_unreadable, nil}
      :missing -> {:unknown, :project_unreadable, nil}
      unknown -> unknown
    end
  end

  @doc """
  The row this read leaves, as the fields to write, and what it says
  happened.
  """
  @spec next(MergeRequestRead.t() | nil, Mouse.t(), result(), DateTime.t()) ::
          {map(), [event()]}
  def next(row, %Mouse{mouse_id: mouse_id, merge_request_url: url}, result, now) do
    prior = prior(row, url)
    now = DateTime.truncate(now, :second)
    base = if prior, do: %{mouse_id: mouse_id}, else: blank(mouse_id, url)
    advance(result, prior, base, now)
  end

  defp blank(mouse_id, url) do
    MergeRequestRead.fields()
    |> Map.new(&{&1, nil})
    |> Map.merge(%{mouse_id: mouse_id, url: url, threads_open: 0, ready: false, missing_reads: 0})
  end

  defp advance({:ok, seen}, prior, base, now) do
    snapshot = seen.snapshot
    state = Atom.to_string(snapshot.state)
    first? = is_nil(prior) or is_nil(prior.seen_note_id)
    pipeline = snapshot.pipeline
    failed = failed_on_head(snapshot)

    {failed_on, seen_failed} =
      cond do
        is_nil(failed) -> {nil, prior && prior.seen_failed_pipeline_id}
        first? -> {nil, failed.id}
        failed.id == prior.seen_failed_pipeline_id -> {nil, failed.id}
        true -> {String.slice(snapshot.head_sha, 0, 8), failed.id}
      end

    attrs =
      Map.merge(base, %{
        state: state,
        head_sha: snapshot.head_sha,
        pipeline_id: pipeline && pipeline.id,
        pipeline: pipeline && Atom.to_string(pipeline.status),
        threads_open: seen.threads_open || (prior && prior.threads_open) || 0,
        notes_count: snapshot.notes_count,
        forge_updated_at: snapshot.updated_at,
        ready: snapshot.ready?,
        seen_note_id: cursor(prior, seen.max_note_id),
        seen_failed_pipeline_id: seen_failed,
        missing_reads: 0,
        read_at: now,
        unread_since: nil,
        unread_reason: nil
      })

    {attrs, moved} = moved(attrs, prior && prior.state, state)
    comments = if first?, do: [], else: seen.new_comments

    wake =
      if comments != [] or failed_on do
        [
          {:would_wake,
           %{
             comments: length(comments),
             authors: comments |> Enum.map(& &1.author) |> Enum.uniq(),
             failed_on: failed_on
           }}
        ]
      else
        []
      end

    {attrs, readable_again(prior) ++ moved ++ wake}
  end

  defp advance({:missing, true}, prior, base, now) do
    count = ((prior && prior.missing_reads) || 0) + 1
    was = prior && prior.state
    gone? = count >= @gone_after

    attrs =
      Map.merge(base, %{
        state: if(gone?, do: "gone", else: was),
        missing_reads: count,
        read_at: now,
        unread_since: nil,
        unread_reason: nil
      })

    {attrs, readable_again(prior) ++ if(gone? and was != "gone", do: [:gone], else: [])}
  end

  defp advance({:unknown, reason, _retry}, prior, base, now) do
    since = prior && prior.unread_since
    attrs = Map.merge(base, %{unread_since: since || now, unread_reason: inspect(reason)})
    {attrs, if(since, do: [], else: [{:unreadable, reason}])}
  end

  defp failed_on_head(%{pipeline: %{status: :failed, sha: sha} = pipeline, head_sha: sha})
       when is_binary(sha),
       do: pipeline

  defp failed_on_head(_snapshot), do: nil

  defp cursor(nil, max_id), do: max_id || 0
  defp cursor(%{seen_note_id: nil}, max_id), do: max_id || 0
  defp cursor(%{seen_note_id: seen}, nil), do: seen
  defp cursor(%{seen_note_id: seen}, max_id), do: max(seen, max_id)

  defp moved(attrs, was, "merged") when was != "merged", do: {attrs, [:merged]}
  defp moved(attrs, was, "closed") when was != "closed", do: {attrs, [:closed]}

  defp moved(attrs, was, "open") when was in ["closed", "gone"],
    do: {Map.put(attrs, :asked_at, nil), [:reopened]}

  defp moved(attrs, _was, _state), do: {attrs, []}

  defp readable_again(%{unread_since: %DateTime{}}), do: [:readable_again]
  defp readable_again(_prior), do: []

  @doc """
  How long until `row`'s next read: `interval_ms` after one that worked; as
  long as reads have been failing, between that and 15 minutes, after one that
  did not; and never sooner than the forge's own `retry_after_ms`.
  """
  @spec wait_ms(
          MergeRequestRead.t() | map() | nil,
          pos_integer() | nil,
          pos_integer(),
          DateTime.t()
        ) ::
          pos_integer()
  def wait_ms(row, retry_after_ms, interval_ms, now) do
    wait =
      case row do
        %{unread_since: %DateTime{} = since} ->
          now |> DateTime.diff(since, :millisecond) |> max(interval_ms) |> min(@longest_wait_ms)

        _ ->
          interval_ms
      end

    max(wait, retry_after_ms || 0)
  end

  @doc "The owl's log line for `event` on `branch`'s merge request `label`."
  @spec line(event(), String.t(), String.t()) :: String.t()
  def line({:would_wake, wake}, branch, label),
    do: "#{branch}: would wake for #{label} — #{wake_reasons(wake)}"

  def line(:merged, branch, label),
    do: "#{branch}: #{label} merged on the forge — fetching the base now"

  def line(:closed, branch, label), do: "#{branch}: #{label} closed on the forge"
  def line(:gone, branch, label), do: "#{branch}: #{label} is gone from the forge"
  def line(:reopened, branch, label), do: "#{branch}: #{label} open again"

  def line({:unreadable, reason}, branch, label),
    do: "#{branch}: #{label} cannot be read (#{inspect(reason)}) — shown as unread until it can"

  def line(:readable_again, branch, label), do: "#{branch}: #{label} reads again"

  defp wake_reasons(%{comments: n, authors: authors, failed_on: sha}) do
    comments =
      case n do
        0 -> nil
        1 -> "1 new comment by #{Enum.join(authors, ", ")}"
        n -> "#{n} new comments by #{Enum.join(authors, ", ")}"
      end

    failed = if sha, do: "pipeline failed on #{sha}"
    [comments, failed] |> Enum.reject(&is_nil/1) |> Enum.join("; ")
  end
end
