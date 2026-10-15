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

  **A merge request opened by hand is found by its branch.** `find_each/4`
  looks on the forge for one open from a mouse's branch, into any branch, once
  that branch is on `origin` and no merge request waits on it; the house
  records what it finds, and from then on it is read like any other
  (ADR-0060).
  """

  alias Whiska.Forge
  alias Whiska.Git
  alias Whiska.Schema.MergeRequestRead
  alias Whiska.Schema.Mouse
  alias Whiska.Storage

  @gone_after 3
  @unread_after_s 180
  @longest_retry_ms 3_600_000
  @longest_wait_ms 900_000

  @type comment :: %{
          required(:id) => pos_integer(),
          required(:author) => String.t(),
          required(:discussion_id) => String.t() | nil,
          optional(:open) => true
        }

  @type seen :: %{
          snapshot: Forge.snapshot(),
          threads_open: non_neg_integer() | nil,
          threads_answered: non_neg_integer() | nil,
          max_note_id: pos_integer() | nil,
          new_comments: [comment()],
          open_threads: [comment()] | nil
        }

  @type result ::
          {:ok, seen()} | {:missing, true} | {:unknown, term(), pos_integer() | nil}

  @type event ::
          {:review, MergeRequestRead.review()}
          | :merged
          | :closed
          | :gone
          | :reopened
          | {:unreadable, term()}
          | :readable_again

  @typedoc "When a branch is next looked up: its `origin` head then, and the wait."
  @type find_entry :: %{head: String.t(), due: integer(), wait_ms: pos_integer()}

  @type found :: Forge.answer(String.t() | nil)

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

  defp still_open?(nil, _url), do: true
  defp still_open?(%MergeRequestRead{url: url, state: "open"}, url), do: true
  defp still_open?(_not_read_open, _url), do: false

  @doc """
  Every mouse a merge request is looked for: a current one not dropped, with
  a branch, and no merge request waiting on it.
  """
  @spec unrecorded() :: [Mouse.t()]
  def unrecorded do
    for %Mouse{removed_at: nil, branch: branch} = mouse <- Storage.current_mice(),
        is_binary(branch),
        not Mouse.merge_request_waiting?(mouse),
        do: mouse
  end

  @doc """
  Look on the forge `origin` names for a merge request open from each of
  `mice`'s branches, one into its base first: only a branch `origin` has, and only when
  its `origin` head moved or `due` says it is time, as of `now`, a monotonic
  time. Nothing is looked up when `origin` is no forge that can be. A forge
  that says to wait is not called again this round: the rest take its answer.
  """
  @spec find_each([Mouse.t()], %{String.t() => find_entry()}, context(), integer()) ::
          [{Mouse.t(), String.t(), found()}]
  def find_each(mice, due, context, now) do
    case Forge.origin_project(context.cwd) do
      {:ok, project} ->
        run = run(project, context)

        {found, _told} =
          Enum.flat_map_reduce(mice, nil, fn mouse, told ->
            with {:ok, head} <- Git.remote_head(context.cwd, mouse.branch),
                 true <- find_due?(due[mouse.mouse_id], head, now) do
              base =
                case Git.base_of(context.cwd, mouse.base) do
                  {:ok, base} -> base
                  {:error, _unreadable} -> nil
                end

              result = told || project.forge.open_from(project, mouse.branch, base, run)
              {[{mouse, head, result}], told || told(result)}
            else
              _ -> {[], told}
            end
          end)

        found

      :error ->
        []
    end
  end

  defp find_due?(nil, _head, _now), do: true
  defp find_due?(%{head: head, due: due}, head, now), do: now >= due
  defp find_due?(_moved, _head, _now), do: true

  defp told({:unknown, _reason, ms} = told) when is_integer(ms), do: told
  defp told(_result), do: nil

  @doc """
  When a branch looked up at `started` with nothing found is next: after
  `interval_ms`, then twice as long each time while its `origin` head stays
  `head`, up to 15 minutes; never sooner than the forge's retry time.
  """
  @spec find_next(find_entry() | nil, String.t(), found(), pos_integer(), integer()) ::
          find_entry()
  def find_next(entry, head, result, interval_ms, started) do
    wait =
      case entry do
        %{head: ^head, wait_ms: last} -> min(2 * last, @longest_wait_ms)
        _ -> interval_ms
      end

    retry_ms =
      case result do
        {:unknown, _reason, ms} when is_integer(ms) -> min(ms, @longest_retry_ms)
        _ -> 0
      end

    wait = max(wait, retry_ms)
    %{head: head, due: started + wait, wait_ms: wait}
  end

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

  @doc """
  Read each of `due`, a mouse with its last read, in turn. A forge that says
  to wait is not called again this round: the rest on its host take that
  answer as their own.
  """
  @spec read_each([{Mouse.t(), MergeRequestRead.t() | nil}], context()) ::
          {[{Mouse.t(), MergeRequestRead.t() | nil, result()}], context()}
  def read_each(due, context) do
    {reads, {context, _waiting}} =
      Enum.map_reduce(due, {context, %{}}, fn {mouse, row}, {context, waiting} ->
        {:ok, %{host: host}} = Forge.for_url(mouse.merge_request_url)

        case waiting do
          %{^host => told} ->
            {{mouse, row, told}, {context, waiting}}

          _ ->
            {result, context} = read(mouse, row, context)
            {{mouse, row, result}, {context, wait_on(waiting, host, result)}}
        end
      end)

    {reads, context}
  end

  defp wait_on(waiting, host, {:unknown, _reason, ms} = told) when is_integer(ms),
    do: Map.put(waiting, host, told)

  defp wait_on(waiting, _host, _result), do: waiting

  @doc "Read `mouse`'s merge request on its forge, against `row`, the last read."
  @spec read(Mouse.t(), MergeRequestRead.t() | nil, context()) :: {result(), context()}
  def read(%Mouse{merge_request_url: url, branch: branch}, row, context) do
    {:ok, ref} = Forge.for_url(url)
    run = run(ref, context)
    prior = prior(row, ref.url)

    case ref.forge.merge_request(ref, run) do
      {:ok, %{source_branch: source}} when source != branch ->
        {{:unknown, :other_branch, nil}, context}

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

  # An open thread is read again each time: resolving one may move nothing else.
  defp moved?(prior, snapshot),
    do:
      prior.notes_count != snapshot.notes_count or prior.forge_updated_at != snapshot.updated_at or
        (prior.threads_open || 0) > 0

  defp unread_notes(snapshot),
    do: %{
      snapshot: snapshot,
      threads_open: nil,
      threads_answered: nil,
      max_note_id: nil,
      new_comments: [],
      open_threads: nil
    }

  defp with_notes(ref, run, snapshot, prior, context) do
    with {:ok, %{threads_open: open, notes: notes}} <- ref.forge.notes(ref, run),
         {:ok, {new, threads}, context} <- review_notes(ref, run, notes, prior, context) do
      {answered, context} = answered(notes, ref, run, context)
      max_id = notes |> Enum.map(& &1.id) |> Enum.max(fn -> nil end)

      {{:ok,
        %{
          snapshot: snapshot,
          threads_open: open,
          threads_answered: answered,
          max_note_id: max_id,
          new_comments: new,
          open_threads: threads
        }}, context}
    else
      {:unknown, _reason, _retry} = unknown -> {unknown, context}
      {{:unknown, _reason, _retry} = unknown, context} -> {unknown, context}
      :missing -> {missing(ref, run), context}
    end
  end

  # The new comments past the cursor, none at the first read; and each open
  # thread's newest note, whatever its age, when that is someone else's: a
  # thread whose last word is the account's was answered. Both by members only.
  # A comment whose author cannot be asked about makes the read unknown, so the
  # cursor waits for it; an open thread's only waits for the next read, since
  # it stays open and the read must not fail for as long as it does.
  defp review_notes(ref, run, notes, prior, context) do
    new =
      if is_nil(prior) or is_nil(prior.seen_note_id),
        do: [],
        else: Enum.filter(notes, &(&1.id > prior.seen_note_id and not &1.system?))

    last = last_words(notes)

    with {:ok, new, context} <- by_members(new, ref, run, context) do
      {threads, context} =
        case by_members(last, ref, run, context) do
          {:ok, threads, context} -> {Enum.map(threads, &Map.put(&1, :open, true)), context}
          {_unknown, context} -> {[], context}
        end

      {:ok, {new, threads}, context}
    end
  end

  # Each open thread's newest note, a thread with an id to name it only.
  defp last_words(notes) do
    notes
    |> Enum.filter(&(&1.open? and not &1.system? and is_binary(&1.discussion_id)))
    |> Enum.group_by(& &1.discussion_id)
    |> Enum.map(fn {_thread, notes} -> Enum.max_by(notes, & &1.id) end)
    |> Enum.sort_by(& &1.id)
  end

  # How many open threads end on the account's own word, from the notes
  # already read and the account asked for once. Unknown when the account
  # cannot be, so the row keeps its last count.
  defp answered(notes, ref, run, context) do
    case last_words(notes) do
      [] ->
        {0, context}

      last ->
        case me(ref, run, context) do
          {:ok, me, context} -> {Enum.count(last, &(&1.author_id == me.id)), context}
          {_unknown, context} -> {nil, context}
        end
    end
  end

  defp by_members([], _ref, _run, context), do: {:ok, [], context}

  defp by_members(notes, ref, run, context) do
    with {:ok, me, context} <- me(ref, run, context),
         notes = Enum.reject(notes, &(&1.author_id == me.id)),
         {:ok, context} <- members(notes, ref, run, context) do
      kept = Enum.filter(notes, &context.members[{ref.host, ref.project, &1.author_id}])

      {:ok, Enum.map(kept, &%{id: &1.id, author: &1.author, discussion_id: &1.discussion_id}),
       context}
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

  # Whether each author is a member, asked once and remembered in `context`.
  defp members(notes, ref, run, context) do
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
    |> Map.merge(%{
      mouse_id: mouse_id,
      url: url,
      threads_open: 0,
      threads_answered: 0,
      ready: false,
      missing_reads: 0,
      rounds_unpushed: 0
    })
  end

  defp advance({:ok, seen}, prior, base, now) do
    snapshot = seen.snapshot
    state = Atom.to_string(snapshot.state)
    first? = is_nil(prior) or is_nil(prior.seen_note_id)
    pipeline = snapshot.pipeline
    failed = failed_on_head(snapshot)

    {failed_now, seen_failed} =
      cond do
        is_nil(failed) -> {nil, prior && prior.seen_failed_pipeline_id}
        prior && failed.id == prior.seen_failed_pipeline_id -> {nil, failed.id}
        true -> {%{id: failed.id, sha: String.slice(snapshot.head_sha, 0, 8)}, failed.id}
      end

    attrs =
      Map.merge(base, %{
        state: state,
        head_sha: snapshot.head_sha,
        pipeline_id: pipeline && pipeline.id,
        pipeline: pipeline && Atom.to_string(pipeline.status),
        threads_open: seen.threads_open || (prior && prior.threads_open) || 0,
        threads_answered:
          Map.get(seen, :threads_answered) || (prior && prior.threads_answered) || 0,
        notes_count: snapshot.notes_count,
        forge_updated_at: snapshot.updated_at,
        ready: snapshot.ready?,
        blocker: snapshot.blocker && Atom.to_string(snapshot.blocker),
        seen_note_id: cursor(prior, seen.max_note_id),
        seen_failed_pipeline_id: seen_failed,
        missing_reads: 0,
        read_at: now,
        unread_since: nil,
        unread_reason: nil
      })

    {attrs, moved} = moved(attrs, prior && prior.state, state)
    comments = if first?, do: [], else: seen.new_comments
    {comments, attrs} = open_threads(comments, Map.get(seen, :open_threads), prior, attrs)

    if comments != [] or failed_now do
      review = %{comments: comments, pipeline: failed_now}
      attrs = Map.put(attrs, :pending, keep(prior, review))
      {attrs, readable_again(prior) ++ moved ++ [{:review, review}]}
    else
      {attrs, readable_again(prior) ++ moved}
    end
  end

  defp advance({:missing, true}, prior, base, now) do
    count = ((prior && prior.missing_reads) || 0) + 1
    was = prior && prior.state
    # Only a request once read as this mouse's can go: a link to one that was
    # never there says nothing about the branch.
    gone? = count >= @gone_after and not is_nil(was)

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

  # An open thread joins the review once, however old: unless it was counted
  # before, waits in what is kept, or has a new comment in this read. Every
  # thread the review names, what was kept included, is then counted, so a thread a round left open
  # comes back only through a new comment in it.
  defp open_threads(comments, open, prior, attrs) do
    handed = MergeRequestRead.threads_handed(prior || %{})
    kept = ((prior && MergeRequestRead.pending(prior)) || %{comments: []}).comments
    taken = MapSet.new(handed ++ Enum.map(kept ++ comments, & &1.discussion_id))

    comments =
      comments ++
        Enum.reject(open || [], &(is_nil(&1.discussion_id) or &1.discussion_id in taken))

    named = Enum.map(kept ++ comments, & &1.discussion_id)

    case Enum.uniq(handed ++ Enum.reject(named, &is_nil/1)) do
      ^handed ->
        {comments, attrs}

      ids ->
        {comments, Map.put(attrs, :threads_handed, MergeRequestRead.encode_threads_handed(ids))}
    end
  end

  # A review read while the last one still waits to be handed over joins it:
  # the comments in the order read, and the newest failed pipeline.
  defp keep(prior, review) do
    case prior && MergeRequestRead.pending(prior) do
      nil ->
        MergeRequestRead.encode_pending(review)

      kept ->
        MergeRequestRead.encode_pending(%{
          comments: kept.comments ++ review.comments,
          pipeline: review.pipeline || kept.pipeline
        })
    end
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
  did not; and never sooner than the forge's own `retry_after_ms`, up to an
  hour.
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

    max(wait, min(retry_after_ms || 0, @longest_retry_ms))
  end

  @doc """
  Whether `row`'s reads have failed for long enough to say so: three minutes.
  One slow or refused read is not news.
  """
  @spec unread?(MergeRequestRead.t() | nil, DateTime.t()) :: boolean()
  def unread?(%{unread_since: %DateTime{} = since}, now),
    do: DateTime.diff(now, since) >= @unread_after_s

  def unread?(_row, _now), do: false

  @doc "The owl's log line for `event` on `branch`'s merge request `label`."
  @spec line(event(), String.t(), String.t()) :: String.t()
  def line({:review, review}, branch, label),
    do: "#{branch}: review for #{label} — #{review_reasons(review)}"

  def line(:merged, branch, label),
    do: "#{branch}: #{label} merged on the forge — fetching the base now"

  def line(:closed, branch, label), do: "#{branch}: #{label} closed on the forge"
  def line(:gone, branch, label), do: "#{branch}: #{label} is gone from the forge"
  def line(:reopened, branch, label), do: "#{branch}: #{label} open again"

  def line({:unreadable, reason}, branch, label),
    do: "#{branch}: #{label} cannot be read (#{inspect(reason)}) — shown as unread until it can"

  def line(:readable_again, branch, label), do: "#{branch}: #{label} reads again"

  defp review_reasons(%{comments: comments, pipeline: pipeline}) do
    {threads, comments} = Enum.split_with(comments, & &1[:open])
    failed = if pipeline, do: "pipeline failed on #{plain(pipeline.sha)}"

    [counted(comments, "new comment"), counted(threads, "open thread"), failed]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("; ")
  end

  defp counted([], _what), do: nil

  defp counted(comments, what) do
    authors = comments |> Enum.map(&plain(&1.author)) |> Enum.uniq() |> Enum.join(", ")

    case length(comments) do
      1 -> "1 #{what} by #{authors}"
      n -> "#{n} #{what}s by #{authors}"
    end
  end

  # A name as the forge sent it, kept to what a username may hold, so the log
  # carries no line or terminal control of the forge's making.
  @doc "A name from the forge with only the characters a username or sha is made of."
  @spec plain(String.t()) :: String.t()
  def plain(name), do: String.replace(name, ~r/[^A-Za-z0-9_.-]/, "")
end
