defmodule Whiska.Storage do
  @moduledoc """
  Opening this house's database — for one CLI invocation, or for as long as the
  owl keeps the house open.

  A hook invocation opens the SQLite file, migrates it if needed, does its one
  job and exits (ADR-0030); an open house (`Whiska.Owl.House`) holds it for its
  whole life. The file itself is permanent — a house exists from the first
  invocation onwards and is never destroyed (ADR-0003, ADR-0007).

  The database sits under the **main checkout's** `.git/`, which every worktree
  shares, so all of a repo's mice land in one house rather than one per worktree.
  Being inside `.git/` also means it is gitignored by construction.
  """

  import Ecto.Query, only: [from: 2]

  alias Whiska.Layout
  alias Whiska.Repo
  alias Whiska.Schema.House
  alias Whiska.Schema.Mouse
  alias Whiska.Schema.Question

  @migrations [
    {1, Whiska.Migrations.V001CreateMiceAndQuestions},
    {2, Whiska.Migrations.V002OwlCollection},
    {3, Whiska.Migrations.V003Delivery},
    {4, Whiska.Migrations.V004Cleanup}
  ]

  @modes ~w(build sniff)
  # The statuses still waiting on the person (ADR-0008).
  @waiting ~w(open sent)

  @doc "The modes a mouse can be in (ADR-0018)."
  def modes, do: @modes

  @doc "Where this repo's house lives."
  @spec database_path(Path.t()) :: Path.t()
  def database_path(main_checkout), do: Path.join(main_checkout, ".git/whiska/whiska.db")

  @doc """
  Open the house, creating and migrating it if this is its first invocation.

  The owl keeps many houses open at once (ADR-0001), each on its own Repo
  instance, so `name:` picks the instance — `nil` for an unnamed one, addressed
  by pid. The calling process is pointed at it (`point_at/1`); every house
  process opens its own and never has to think about it again. The CLI leaves
  the default, and there is one house per VM.
  """
  @spec open(Path.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def open(main_checkout, opts \\ []) do
    path = database_path(main_checkout)
    File.mkdir_p!(Path.dirname(path))
    name = Keyword.get(opts, :name, Repo)

    # An escript cannot ship SQLite's native library inside itself; see
    # Whiska.BundledNIF for the whole story. Has to happen before anything
    # touches Exqlite, since the NIF loads when its module first loads.

    with {:ok, _} <- Whiska.BundledNIF.ensure_loadable(),
         {:ok, _} <- Application.ensure_all_started(:ecto_sql),
         {:ok, _} <- Application.ensure_all_started(:ecto_sqlite3),
         {:ok, pid} <- Repo.start_link([name: name] ++ repo_opts(path)) do
      point_at(name || pid)
      migrate()
      {:ok, pid}
    end
  end

  @doc "Point this process at one house's Repo instance (a dynamic repo)."
  @spec point_at(atom() | pid()) :: :ok
  def point_at(name) do
    Repo.put_dynamic_repo(name)
    :ok
  end

  @doc """
  Close the house again. The file, and everything in it, stays.

  The CLI itself does not need this — it exits, and the VM takes the connection
  with it — but tests open and close many houses in one VM, so shutting down
  cleanly and waiting for it matters there.
  """
  @spec close(pid()) :: :ok
  def close(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      ref = Process.monitor(pid)
      Process.unlink(pid)
      Process.exit(pid, :shutdown)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      after
        5_000 -> :ok
      end
    end

    :ok
  end

  defp repo_opts(path) do
    [
      database: path,
      pool_size: 1,
      journal_mode: :wal,
      busy_timeout: 5_000,
      log: false
    ]
  end

  defp migrate do
    Ecto.Migrator.run(Repo, @migrations, :up, all: true, log: false, log_migrations_sql: false)
  end

  @doc """
  Record this mouse, inserting it the first time and refreshing its labels after.

  `path` and `branch` are live, re-read display labels (ADR-0002), so a renamed
  branch or a moved folder updates the same row rather than creating a second
  one. Nothing is ever deleted here (ADR-0007).
  """
  @spec record_mouse(map()) :: {:ok, Mouse.t()} | {:error, Ecto.Changeset.t()}
  def record_mouse(%{mouse_id: mouse_id} = attrs) do
    case Repo.get(Mouse, mouse_id) do
      nil -> insert_mouse(attrs)
      existing -> refresh_labels(existing, attrs)
    end
  end

  defp insert_mouse(attrs) do
    %Mouse{}
    |> Ecto.Changeset.change(Map.put_new(attrs, :created_at, now()))
    |> Repo.insert()
  end

  defp refresh_labels(existing, attrs) do
    existing
    |> Ecto.Changeset.change(Map.take(attrs, [:path, :branch, :pane]))
    |> Repo.update()
  end

  @doc """
  This mouse's mode.

  Read by the sniff rule on every invocation (ADR-0018). Returns
  `{:error, :no_such_mouse}` rather than guessing, so the caller decides what an
  unreadable mode means — see `Whiska.Hook.PreToolUse`, which treats it as
  `build` and says so loudly.
  """
  @spec mode(String.t()) :: {:ok, String.t()} | {:error, :no_such_mouse}
  def mode(mouse_id) do
    case Repo.get(Mouse, mouse_id) do
      nil -> {:error, :no_such_mouse}
      mouse -> {:ok, mouse.mode}
    end
  end

  @doc """
  Move a mouse between build and sniff.

  The mode lives here rather than in the marker file so it stays keyed to
  `mouse_id` — a renamed branch or a moved worktree does not disturb it — and so
  the marker stays the bare opaque id ADR-0002 describes.
  """
  @spec set_mode(String.t(), String.t()) ::
          {:ok, Mouse.t()} | {:error, :invalid_mode | :no_such_mouse | Ecto.Changeset.t()}
  def set_mode(_mouse_id, mode) when mode not in @modes, do: {:error, :invalid_mode}

  def set_mode(mouse_id, mode) do
    case Repo.get(Mouse, mouse_id) do
      nil ->
        {:error, :no_such_mouse}

      mouse ->
        mouse
        |> Ecto.Changeset.change(%{mode: mode})
        |> Repo.update()
    end
  end

  @doc "One mouse, or nil."
  @spec mouse(String.t()) :: Mouse.t() | nil
  def mouse(mouse_id), do: Repo.get(Mouse, mouse_id)

  @doc "One question, or nil."
  @spec question(integer()) :: Question.t() | nil
  def question(id), do: Repo.get(Question, id)

  @doc """
  Every mouse record that still stands for a worktree of this house, oldest
  first, dead ones included.

  Nothing is ever deleted (ADR-0007), so a house keeps records that no longer
  stand for anything: a second record made for a worktree that was recorded
  once already, and — the case ADR-0030's note left behind — a record whose
  `path` is the ordinary folder a slashed branch nests under, `worktrees/feat`
  holding `worktrees/feat/checkout-form`. Of two records whose folders nest the
  deeper one stands, since git will not carry a branch `feat` and a branch
  `feat/checkout-form` at once — unless the shallower record was made later,
  which is a branch taking back a name every nested one has left. Of two
  records for the same folder, the newer stands.

  A stale record is dropped here rather than at each reader, so everything that
  asks what this house has — `whiska mice`, the board, the owl's pane matching —
  asks the same question and cannot disagree about the answer.
  """
  @spec current_mice() :: [Mouse.t()]
  def current_mice, do: current(Repo.all(from(m in Mouse, order_by: m.created_at)))

  @doc "The current records among `mice`, for a caller that has read them already."
  @spec current([Mouse.t()]) :: [Mouse.t()]
  def current(mice) do
    folders = Map.new(mice, &{&1.mouse_id, folder(&1)})

    Enum.reject(mice, fn mouse ->
      Enum.any?(mice, &supersedes?(&1, mouse, folders))
    end)
  end

  defp folder(%Mouse{path: path}) when is_binary(path),
    do: path |> Layout.canonical() |> Path.split()

  defp folder(_no_path), do: nil

  defp supersedes?(%Mouse{mouse_id: id}, %Mouse{mouse_id: id}, _folders), do: false

  defp supersedes?(other, mouse, folders) do
    case {folders[other.mouse_id], folders[mouse.mouse_id]} do
      {nil, _} ->
        false

      {_, nil} ->
        false

      {theirs, ours} ->
        List.starts_with?(theirs, ours) and stands_instead?(other, mouse, theirs == ours)
    end
  end

  # Of two records for one folder, the newer one stands; a tie goes to the
  # greater id — arbitrary, but the same answer every time it is asked, and one
  # of the two has to go for the house to have one row per worktree.
  #
  # Of two records whose folders nest, the deeper one stands, unless the
  # shallower one was made later: a branch named `feat` can only exist once
  # every `feat/…` branch is gone, and then its record is the current one and
  # the nested record is history.
  defp stands_instead?(other, mouse, same_folder?) do
    case {DateTime.compare(other.created_at, mouse.created_at), same_folder?} do
      {:gt, _} -> true
      {:eq, same} -> not same or other.mouse_id > mouse.mouse_id
      {:lt, _} -> false
    end
  end

  @doc "Every current mouse not marked dead, oldest first."
  @spec alive_mice() :: [Mouse.t()]
  def alive_mice, do: Enum.filter(current_mice(), &is_nil(&1.died_at))

  @doc """
  Record the pane herdr reports for a mouse.

  A pane running Claude in the worktree is a live mouse by definition, so this
  also clears `died_at` — the case where a pane died and a new one was started
  on the same worktree by hand.
  """
  @spec set_pane(String.t(), String.t()) ::
          {:ok, Mouse.t()} | {:error, :no_such_mouse | Ecto.Changeset.t()}
  def set_pane(mouse_id, pane) do
    case Repo.get(Mouse, mouse_id) do
      nil ->
        {:error, :no_such_mouse}

      mouse ->
        mouse
        |> Ecto.Changeset.change(%{pane: pane, died_at: nil})
        |> Repo.update()
    end
  end

  @doc """
  Mark a mouse dead: its pane is gone (ADR-0026).

  The row stays (ADR-0007). Everything of its that was still waiting on the
  person — open *and* sent — cascades to `orphaned` rather than sitting there
  forever: a sent question whose mouse is dead can never be answered, since
  there is nowhere for the answer to land, and while it stayed `sent` it held
  ADR-0008's one delivery slot against every later question. Anything already
  answered, closed or superseded is history and is left alone. Marking an
  already-dead mouse changes nothing.
  """
  @spec mark_dead(String.t()) :: {:ok, Mouse.t()} | {:error, :no_such_mouse | Ecto.Changeset.t()}
  def mark_dead(mouse_id) do
    case Repo.get(Mouse, mouse_id) do
      nil ->
        {:error, :no_such_mouse}

      %Mouse{died_at: %DateTime{}} = mouse ->
        release(mouse_id)
        {:ok, mouse}

      mouse ->
        Repo.transaction(fn ->
          release(mouse_id)

          mouse
          |> Ecto.Changeset.change(%{died_at: now()})
          |> Repo.update!()
        end)
    end
  end

  @doc """
  Release every question nothing can act on any more (ADR-0057).

  Nothing that cannot be answered may hold ADR-0008's one delivery slot, so
  what is still waiting for a mouse that is dead (ADR-0026), or for a record
  that no longer stands for a worktree of this house — the phantom a slashed
  branch's parent folder used to mint, and any other stale record — is settled
  as `orphaned` here. It is kept with that status (ADR-0007), counted on the
  board's own `orphaned` line (ADR-0051) and listed apart by
  `whiska questions`, which says there is nowhere to reply.

  `mark_dead/1` does the same for one mouse at the moment it dies; this is the
  sweep that catches what arrived after it, and it is run before every delivery
  so the slot is judged by what is alive now. Returns what it released.

  A `done` report is outside it. Nothing is waiting on the person in one, so it
  neither takes the slot nor holds it (ADR-0008, note of 2026-10-01) — and a
  branch whose mouse is gone is exactly the one the person still wants to hear
  finished.
  """
  @spec release_unanswerable() :: [Question.t()]
  def release_unanswerable do
    # The waiting questions are an indexed read of a handful of rows; working
    # out which records are current walks every record's path. A house with
    # nothing waiting is the common case and pays only the first.
    case Enum.reject(questions(), &(&1.kind == "done")) do
      [] -> []
      waiting -> release_all(unanswerable(waiting))
    end
  end

  defp unanswerable(waiting) do
    answerable =
      current_mice()
      |> Enum.filter(&is_nil(&1.died_at))
      |> MapSet.new(& &1.mouse_id)

    Enum.reject(waiting, &MapSet.member?(answerable, &1.mouse_id))
  end

  defp release_all([]), do: []

  # The status is read and written in two statements, and `whiska reply` runs in
  # a process of its own: the guard is what stops an answer that landed in
  # between being stamped over.
  defp release_all(questions) do
    ids = Enum.map(questions, & &1.id)

    {_, _} =
      Repo.update_all(
        from(q in Question, where: q.id in ^ids and q.status in ^@waiting),
        set: [status: "orphaned"]
      )

    questions
  end

  # Everything one mouse left waiting, out of the slot and into `orphaned`.
  # Anything already answered, closed or superseded is history and is left
  # alone.
  defp release(mouse_id) do
    Repo.update_all(
      from(q in Question, where: q.mouse_id == ^mouse_id and q.status in ^@waiting),
      set: [status: "orphaned"]
    )
  end

  @doc """
  Mark a mouse's worktree taken down (ADR-0058).

  The row is stamped, never deleted: ADR-0007's reasoning about the record is
  untouched by its worktree half being superseded, and a stamped row is what
  keeps the sweep from ever looking at that folder again. The mouse is marked
  dead in the same breath — its pane went with its worktree, so everything
  `mark_dead/1` does to what it left waiting applies here too.

  Idempotent: a mouse already marked is returned unchanged, so a second sweep
  over the same worktree is a no-op rather than a fresh timestamp.
  """
  @spec mark_removed(String.t()) ::
          {:ok, Mouse.t()} | {:error, :no_such_mouse | Ecto.Changeset.t()}
  def mark_removed(mouse_id) do
    case Repo.get(Mouse, mouse_id) do
      nil ->
        {:error, :no_such_mouse}

      %Mouse{removed_at: %DateTime{}} = mouse ->
        {:ok, mouse}

      _ ->
        with {:ok, _} <- mark_dead(mouse_id) do
          Mouse
          |> Repo.get(mouse_id)
          |> Ecto.Changeset.change(%{removed_at: now()})
          |> Repo.update()
        end
    end
  end

  @doc """
  Record a question the owl collected from the doorstep (ADR-0036).

  An entry whose worktree is gone passes `orphaned`; everything else, a `done`
  report included, arrives `open` and is told in its turn (ADR-0009). Kind and
  status are checked against the lists on `Whiska.Schema.Question`, so nothing
  unclassifiable is stored.
  """
  @spec record_question(map()) :: {:ok, Question.t()} | {:error, Ecto.Changeset.t()}
  def record_question(attrs) do
    %Question{}
    |> Ecto.Changeset.cast(attrs, [:mouse_id, :text, :kind, :status, :asked_at])
    |> Ecto.Changeset.put_change(:asked_at, Map.get(attrs, :asked_at) || now())
    |> Ecto.Changeset.validate_required([:mouse_id, :text, :kind, :status])
    |> Ecto.Changeset.validate_inclusion(:kind, Question.kinds())
    |> Ecto.Changeset.validate_inclusion(:status, Question.statuses())
    |> Repo.insert()
  end

  # -- the main session ---------------------------------------------------------

  @doc "The pane `whiska start` recorded as this house's main session, or nil."
  @spec main_pane() :: String.t() | nil
  def main_pane do
    case Repo.one(from(h in House, limit: 1)) do
      nil -> nil
      house -> house.main_pane
    end
  end

  @doc """
  Record the main session's pane (ADR-0020). One per house: recording again
  replaces the earlier pane.
  """
  @spec set_main_pane(String.t()) :: :ok
  def set_main_pane(pane) do
    attrs = %{main_pane: pane, started_at: now()}

    case Repo.one(from(h in House, limit: 1)) do
      nil -> %House{} |> Ecto.Changeset.change(attrs) |> Repo.insert!()
      house -> house |> Ecto.Changeset.change(attrs) |> Repo.update!()
    end

    :ok
  end

  # -- the delivery queue (ADR-0008) -------------------------------------------

  @doc "The oldest open question — the next one to deliver — or nil."
  @spec next_open() :: Question.t() | nil
  def next_open do
    Repo.one(from(q in Question, where: q.status == "open", order_by: q.id, limit: 1))
  end

  @doc """
  The oldest `done` report still waiting to be told, or nil.

  A finished line is not a question: nothing is waiting on the person, so it
  never waits for the one delivery slot and never holds it (ADR-0008, note of
  2026-10-01). It is read apart from `next_open/0` for exactly that reason.
  """
  @spec next_done() :: Question.t() | nil
  def next_done do
    Repo.one(
      from(q in Question,
        where: q.status == "open" and q.kind == "done",
        order_by: q.id,
        limit: 1
      )
    )
  end

  @doc """
  The question that has been delivered and is waiting for its answer, or nil.

  Its mouse comes with it: whoever holds the slot, `whiska doctor` has to be
  able to say whether anything is still alive to answer (a dead one's question
  is orphaned by `mark_dead/1`, so a live slot-holder is the normal case).
  """
  @spec sent() :: Question.t() | nil
  def sent do
    Repo.one(
      from(q in Question, where: q.status == "sent", order_by: q.id, limit: 1, preload: [:mouse])
    )
  end

  @doc "How many questions are open — waiting in the queue, not yet delivered."
  @spec open_count() :: non_neg_integer()
  def open_count do
    Repo.one(from(q in Question, where: q.status == "open", select: count(q.id)))
  end

  @doc """
  Every question still waiting on the person: open and sent, oldest first, with
  its mouse loaded. The one query behind `whiska questions` and the statusline's
  count (ADR-0027).
  """
  @spec questions() :: [Question.t()]
  def questions, do: questions_with_status(@waiting)

  @doc """
  Every question nothing can act on any more, oldest first, with its mouse.

  Its mouse died (ADR-0026) or its worktree is gone (ADR-0036). Kept forever
  (ADR-0007), never delivered, and shown apart from what the person can still
  answer: `whiska questions` lists them under their own heading and the board
  counts them on its own `🐱 n orphaned` line (ADR-0051).
  """
  @spec orphaned_questions() :: [Question.t()]
  def orphaned_questions, do: questions_with_status(["orphaned"])

  defp questions_with_status(statuses) do
    Repo.all(from(q in Question, where: q.status in ^statuses, order_by: q.id, preload: [:mouse]))
  end

  @doc "A question has been delivered to the main session."
  @spec mark_sent(integer()) ::
          {:ok, Question.t()} | {:error, :no_such_question | :not_open | Ecto.Changeset.t()}
  def mark_sent(id) do
    case Repo.get(Question, id) do
      nil -> {:error, :no_such_question}
      %Question{status: "open"} = q -> update_status(q, %{status: "sent", sent_at: now()})
      %Question{} -> {:error, :not_open}
    end
  end

  @doc """
  Answer a question by id (ADR-0005). Open or sent only: an answer to anything
  already settled has nowhere to land.
  """
  @spec answer(integer(), String.t()) ::
          {:ok, Question.t()} | {:error, :no_such_question | :not_answerable | Ecto.Changeset.t()}
  def answer(id, text) do
    settle(id, %{status: "answered", answer: text})
  end

  @doc """
  Close a question by hand, with no answer. Open, sent, or orphaned: an
  orphaned question's answer went to its dead mouse's worktree some other way.
  """
  @spec close_question(integer()) ::
          {:ok, Question.t()} | {:error, :no_such_question | :not_answerable | Ecto.Changeset.t()}
  def close_question(id), do: settle(id, %{status: "closed"}, @waiting ++ ["orphaned"])

  defp settle(id, attrs, from \\ @waiting) do
    case Repo.get(Question, id) do
      nil ->
        {:error, :no_such_question}

      %Question{status: s} = q ->
        if s in from, do: update_status(q, attrs), else: {:error, :not_answerable}
    end
  end

  defp update_status(question, attrs) do
    question |> Ecto.Changeset.change(attrs) |> Repo.update()
  end

  @doc """
  A newer question from a mouse supersedes its earlier open and sent ones: the
  mouse has moved past them, so an answer could no longer land. Settled history
  is untouched. Returns how many were superseded.
  """
  @spec supersede_earlier(Question.t()) :: {:ok, non_neg_integer()}
  def supersede_earlier(%Question{id: id, mouse_id: mouse_id}) do
    {n, _} =
      Repo.update_all(
        from(q in Question,
          where: q.mouse_id == ^mouse_id and q.id < ^id and q.status in ^@waiting
        ),
        set: [status: "superseded"]
      )

    {:ok, n}
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  @doc false
  def all(schema), do: Repo.all(from(s in schema, order_by: s.mouse_id))

  @doc "The newest migration this build knows — what a freshly opened house is at."
  @spec latest_schema_version() :: pos_integer()
  def latest_schema_version, do: @migrations |> Enum.map(&elem(&1, 0)) |> Enum.max()

  @doc "The highest migration this house has applied — what `whiska doctor` reports."
  @spec schema_version() :: non_neg_integer()
  def schema_version do
    Repo |> Ecto.Migrator.migrated_versions() |> Enum.max(fn -> 0 end)
  end
end
