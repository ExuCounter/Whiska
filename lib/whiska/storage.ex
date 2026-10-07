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
    {4, Whiska.Migrations.V004Cleanup},
    {5, Whiska.Migrations.V005Landing},
    {6, Whiska.Migrations.V006Pickup},
    {7, Whiska.Migrations.V007Shape},
    {8, Whiska.Migrations.V008Effort},
    {9, Whiska.Migrations.V009ShapedAs},
    {10, Whiska.Migrations.V010HoldAndFocus},
    {11, Whiska.Migrations.V011AnswerTaken}
  ]

  @modes ~w(build sniff)
  # The statuses still waiting on the person (ADR-0008).
  @waiting ~w(open sent)

  @busy_timeout 5_000

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
         :ok <- openable(path),
         {:ok, pid} <- Repo.start_link([name: name] ++ repo_opts(path)) do
      point_at(name || pid)
      migrated(pid)
    end
  end

  # A database that is corrupt or locked raises from inside the migration, after
  # the Repo process is already up. Left running, a named one would be found as
  # `{:already_started, _}` by the next open in this VM, and an unnamed one would
  # simply leak, so it is shut here before the failure travels on.
  defp migrated(pid) do
    migrate()
    {:ok, pid}
  catch
    kind, reason ->
      close(pid)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  @doc """
  Run `work` against one house, on a connection of its own, then shut it.

  The connection is unnamed, so any number of these can run at once in one VM
  — the owl answering hooks for several repos at the same moment — without any
  of them finding another's house under the one name `Whiska.Repo`. The process
  is pointed back at whatever it was pointed at before, so a caller that already
  had a house open keeps it.

  Returns what `work` returns, or `{:error, reason}` when the house will not
  open. Anything `work` raises still raises, after the connection is shut.
  """
  @spec within(Path.t(), (-> result)) :: result | {:error, term()} when result: term()
  def within(main_checkout, work) do
    before = Repo.get_dynamic_repo()

    try do
      case open(main_checkout, name: nil) do
        {:ok, pid} ->
          try do
            work.()
          after
            close(pid)
          end

        {:error, _} = error ->
          error
      end
    after
      point_at(before)
    end
  end

  # A file SQLite cannot open or read — a directory in its place, no
  # permission, something that is not a database — is tried once here, because
  # the pool retries a failed connect with backoff and only gives up, raising,
  # seconds later inside the migration. SQLite opens lazily, so it is read too,
  # with the pool's own busy timeout so a house mid-write is waited for.
  defp openable(path) do
    case read_once(path) do
      :ok -> :ok
      {:error, reason} -> {:error, {:cannot_open, reason}}
    end
  end

  defp read_once(path) do
    with {:ok, conn} <- Exqlite.Sqlite3.open(path) do
      result =
        with :ok <- Exqlite.Sqlite3.execute(conn, "PRAGMA busy_timeout = #{@busy_timeout}"),
             do: Exqlite.Sqlite3.execute(conn, "PRAGMA schema_version")

      Exqlite.Sqlite3.close(conn)
      result
    end
  end

  @doc "Point this process at one house's Repo instance (a dynamic repo)."
  @spec point_at(atom() | pid() | nil) :: :ok
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
      busy_timeout: @busy_timeout,
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
  one. `ran_on` is refreshed the same way, by every turn that names its model.
  Nothing is ever deleted here (ADR-0007).
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

  # A turn that did not say which model it ran on leaves the last one that did.
  defp refresh_labels(existing, attrs) do
    attrs = if attrs[:ran_on], do: attrs, else: Map.delete(attrs, :ran_on)

    existing
    |> Ecto.Changeset.change(Map.take(attrs, [:path, :branch, :pane, :ran_on]))
    |> Repo.update()
  end

  @doc """
  This mouse's mode, as the rules read it.

  Read by the sniff rule on every invocation (ADR-0018). A mouse nobody shaped
  is `"unshaped"` whatever its stored mode, and may read but not write
  (ADR-0069). Returns
  `{:error, :no_such_mouse}` rather than guessing, so the caller decides what an
  unreadable mode means — see `Whiska.Hook.PreToolUse`, which treats it as
  `build` and says so loudly.
  """
  @spec mode(String.t()) :: {:ok, String.t()} | {:error, :no_such_mouse}
  def mode(mouse_id) do
    case Repo.get(Mouse, mouse_id) do
      nil -> {:error, :no_such_mouse}
      mouse -> {:ok, mode_of(mouse)}
    end
  end

  @doc "The mode a record already read says: `unshaped` until somebody chose one (ADR-0069)."
  @spec mode_of(Mouse.t()) :: String.t()
  def mode_of(%Mouse{shaped_at: nil}), do: "unshaped"
  def mode_of(%Mouse{mode: mode}), do: mode

  @doc """
  Give a mouse nobody shaped its mode.

  The mode lives here rather than in the marker file so it stays keyed to
  `mouse_id` — a renamed branch or a moved worktree does not disturb it — and so
  the marker stays the bare opaque id ADR-0002 describes.

  A mode somebody chose is a shape: this stamps `shaped_at`, so
  `whiska mode build` is what lets a mouse nobody shaped write (ADR-0069). A mouse
  that has a shape keeps its mode for good (ADR-0074).
  """
  @spec set_mode(String.t(), String.t()) ::
          {:ok, Mouse.t()}
          | {:error, :invalid_mode | :no_such_mouse | :already_shaped | Ecto.Changeset.t()}
  def set_mode(_mouse_id, mode) when mode not in @modes, do: {:error, :invalid_mode}

  def set_mode(mouse_id, mode) do
    case Repo.get(Mouse, mouse_id) do
      nil ->
        {:error, :no_such_mouse}

      %Mouse{shaped_at: %DateTime{}} ->
        {:error, :already_shaped}

      mouse ->
        mouse
        |> Ecto.Changeset.change(%{mode: mode, shaped_at: now()})
        |> Repo.update()
    end
  end

  @doc """
  Give a mouse its shape: the mode, and the model and effort it was started on
  (ADR-0069).

  Run by the spawn, in the new worktree, before Claude starts — so the first
  tool call a sniff mouse makes is already judged as sniff. `shaped_at` is what
  tells this mouse apart from one nobody shaped, which may not write.
  `shaped_as` keeps the mode the model and effort were chosen with.
  """
  @spec shape(String.t(), String.t(), String.t() | nil, String.t() | nil) ::
          {:ok, Mouse.t()} | {:error, :invalid_mode | :no_such_mouse | Ecto.Changeset.t()}
  def shape(_mouse_id, mode, _model, _effort) when mode not in @modes,
    do: {:error, :invalid_mode}

  def shape(mouse_id, mode, model, effort) do
    case Repo.get(Mouse, mouse_id) do
      nil ->
        {:error, :no_such_mouse}

      mouse ->
        mouse
        |> Ecto.Changeset.change(%{
          mode: mode,
          shaped_as: mode,
          model: model,
          effort: effort,
          ran_on: nil,
          shaped_at: now()
        })
        |> Repo.update()
    end
  end

  @doc "One mouse, or nil."
  @spec mouse(String.t()) :: Mouse.t() | nil
  def mouse(mouse_id), do: Repo.get(Mouse, mouse_id)

  @doc "One question, or nil."
  @spec question(integer()) :: Question.t() | nil
  def question(id), do: Repo.get(Question, id)

  @doc "The question a mouse asked last, whatever became of it, or nil."
  @spec latest_question(String.t()) :: Question.t() | nil
  def latest_question(mouse_id) do
    Repo.one(
      from(q in Question,
        where: q.mouse_id == ^mouse_id,
        order_by: [desc: q.asked_at, desc: q.id],
        limit: 1
      )
    )
  end

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
  person — open *and* sent — cascades out of the queue rather than sitting
  there forever: a sent question whose mouse is dead can never be answered,
  since there is nowhere for the answer to land, and while it stayed `sent` it
  held ADR-0008's one delivery slot against every later question. Where it
  cascades to depends on the branch: `settled` for a mouse whose branch has
  landed, since the merge was the answer, and `orphaned` for one whose work
  never did (ADR-0064). Anything already answered, closed or superseded is
  history and is left alone. Marking an already-dead mouse changes nothing.
  """
  @spec mark_dead(String.t()) :: {:ok, Mouse.t()} | {:error, :no_such_mouse | Ecto.Changeset.t()}
  def mark_dead(mouse_id) do
    case Repo.get(Mouse, mouse_id) do
      nil ->
        {:error, :no_such_mouse}

      %Mouse{died_at: %DateTime{}} = mouse ->
        release(mouse)
        {:ok, mouse}

      mouse ->
        Repo.transaction(fn ->
          release(mouse)

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
  branch's parent folder used to mint, and any other stale record — is taken
  out of the queue here: `settled` where the mouse's branch landed, `orphaned`
  where it did not (ADR-0064). Either is kept (ADR-0007); an orphan is counted
  on the main checkout's sidebar line and listed apart by
  `whiska questions`, which says there is nowhere to reply.

  `mark_dead/1` does the same for one mouse at the moment it dies; this is the
  sweep that catches what arrived after it, and it is run before every delivery
  so the slot is judged by what is alive now. Returns what it released.

  A `done` report is outside it. Nothing is waiting on the person in one, so it
  never holds the slot (ADR-0008, note of 2026-10-06) — and a branch whose
  mouse is gone is exactly the one the person still wants to hear finished.
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

  defp release_all(questions) do
    landed =
      Repo.all(from(m in Mouse, where: not is_nil(m.landed_at), select: m.mouse_id))
      |> MapSet.new()

    questions
    |> Enum.group_by(&if(MapSet.member?(landed, &1.mouse_id), do: "settled", else: "orphaned"))
    |> Enum.each(fn {status, released} -> stamp(released, status) end)

    questions
  end

  # The status is read and written in two statements, and `whiska reply` runs in
  # a process of its own: the guard is what stops an answer that landed in
  # between being stamped over.
  defp stamp(questions, status) do
    ids = Enum.map(questions, & &1.id)

    {_, _} =
      Repo.update_all(
        from(q in Question, where: q.id in ^ids and q.status in ^@waiting),
        set: [status: status]
      )
  end

  # Everything one mouse left waiting, out of the slot and into its terminal
  # status. Anything already answered, closed or superseded is history and is
  # left alone.
  defp release(%Mouse{mouse_id: mouse_id} = mouse) do
    Repo.update_all(
      from(q in Question, where: q.mouse_id == ^mouse_id and q.status in ^@waiting),
      set: [status: terminal_for(mouse)]
    )
  end

  @doc """
  What a question of this mouse becomes once nothing can act on it (ADR-0064).

  `settled` where the branch landed, since the merge was the answer, and
  `orphaned` where it did not. A mouse nobody has a record of is `orphaned`:
  nothing is known to have landed.

  Read by collection as well as by the cascade, so a question arriving after
  its worktree has gone lands in the same place as one that was already there.
  """
  @spec terminal_status(String.t()) :: String.t()
  def terminal_status(mouse_id) when is_binary(mouse_id),
    do: Mouse |> Repo.get(mouse_id) |> terminal_for()

  defp terminal_for(%Mouse{landed_at: %DateTime{}}), do: "settled"
  defp terminal_for(_no_landing), do: "orphaned"

  @doc """
  Mark a mouse's branch landed in the base (ADR-0064).

  The merge is the answer to everything that mouse left waiting, so a question
  of its that nothing can reach any more settles rather than orphaning. Two
  orders have to give the same result — the branch landing before its pane goes
  and after it — so this settles what the mouse already had `orphaned` as well
  as stamping the row, and `mark_dead/1` reads the stamp for the other order.

  Anything still answerable is untouched: a live mouse's open question is the
  person's to answer whether or not the branch has landed.

  Idempotent: the first landing date stands.
  """
  @spec mark_landed(String.t()) ::
          {:ok, Mouse.t()} | {:error, :no_such_mouse | Ecto.Changeset.t()}
  def mark_landed(mouse_id) do
    case Repo.get(Mouse, mouse_id) do
      nil ->
        {:error, :no_such_mouse}

      %Mouse{landed_at: %DateTime{}} = mouse ->
        {:ok, mouse}

      mouse ->
        Repo.transaction(fn ->
          Repo.update_all(
            from(q in Question, where: q.mouse_id == ^mouse_id and q.status == "orphaned"),
            set: [status: "settled"]
          )

          mouse
          |> Ecto.Changeset.change(%{landed_at: now()})
          |> Repo.update!()
        end)
    end
  end

  @doc """
  Mark a mouse's worktree taken down (ADR-0061).

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
  Record that herdr has seen this mouse's pane start working (ADR-0067).

  The only evidence Whiska keeps that a turn began. A turn ends by reaching the
  doorstep, so a stamp with nothing collected after it is a turn that died.
  """
  @spec set_working(String.t(), DateTime.t()) ::
          {:ok, Mouse.t()} | {:error, :no_such_mouse | Ecto.Changeset.t()}
  def set_working(mouse_id, at), do: stamp_mouse(mouse_id, :worked_at, at)

  @doc """
  Record that the owl has typed a line into this mouse's pane to carry a died
  turn on, or take that record back (ADR-0067).

  `nil` is what a refused line writes back: nothing was typed, so the one
  attempt has not been spent.
  """
  @spec set_picked_up(String.t(), DateTime.t() | nil) ::
          {:ok, Mouse.t()} | {:error, :no_such_mouse | Ecto.Changeset.t()}
  def set_picked_up(mouse_id, at), do: stamp_mouse(mouse_id, :picked_up_at, at)

  defp stamp_mouse(mouse_id, field, at) do
    case Repo.get(Mouse, mouse_id) do
      nil -> {:error, :no_such_mouse}
      mouse -> mouse |> Ecto.Changeset.change(%{field => truncate(at)}) |> Repo.update()
    end
  end

  defp truncate(%DateTime{} = at), do: DateTime.truncate(at, :second)
  defp truncate(nil), do: nil

  @doc """
  Every mouse whose last pickup has not been followed by anything reaching the
  doorstep, and when it was picked up (ADR-0067).

  The branches the sidebar says were picked up: once the nudged turn ends, the
  pickup is history rather than news, and the line goes back to saying what the
  mouse is doing.
  """
  @spec picked_up() :: %{String.t() => DateTime.t()}
  def picked_up do
    from(m in Mouse,
      where: not is_nil(m.picked_up_at) and is_nil(m.removed_at),
      left_join: q in Question,
      on: q.mouse_id == m.mouse_id and q.asked_at >= m.picked_up_at,
      where: is_nil(q.id),
      select: {m.mouse_id, m.picked_up_at}
    )
    |> Repo.all()
    |> Map.new()
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

  # -- hold and focus (ADR-0079) ----------

  @doc """
  Put a mouse on hold: its next tool call is refused, nothing of its is
  delivered, and it is never offered for landing, until `lift_hold/1`.

  Idempotent: the first stamp stands, so `hold` twice is one hold.
  """
  @spec hold(String.t()) :: {:ok, Mouse.t()} | {:error, :no_such_mouse | Ecto.Changeset.t()}
  def hold(mouse_id) do
    case Repo.get(Mouse, mouse_id) do
      nil -> {:error, :no_such_mouse}
      %Mouse{held_at: %DateTime{}} = mouse -> {:ok, mouse}
      mouse -> mouse |> Ecto.Changeset.change(%{held_at: now()}) |> Repo.update()
    end
  end

  @doc "Lift a mouse's hold. Lifting one that was never there is fine."
  @spec lift_hold(String.t()) ::
          {:ok, Mouse.t()} | {:error, :no_such_mouse | Ecto.Changeset.t()}
  def lift_hold(mouse_id) do
    case Repo.get(Mouse, mouse_id) do
      nil -> {:error, :no_such_mouse}
      %Mouse{held_at: nil} = mouse -> {:ok, mouse}
      mouse -> mouse |> Ecto.Changeset.change(%{held_at: nil}) |> Repo.update()
    end
  end

  @doc """
  The ids of every live mouse on hold. A dead one's hold is not listed: there
  is nothing left to stop, and nothing of its is waiting anyway (ADR-0026).
  """
  @spec held_ids() :: MapSet.t(String.t())
  def held_ids do
    alive_mice()
    |> Enum.filter(&match?(%DateTime{}, &1.held_at))
    |> MapSet.new(& &1.mouse_id)
  end

  @doc """
  The mouse this house is focused on, or nil — nil too once that mouse is dead
  or removed, so a focus cannot outlive its mouse and leave every other mouse
  waiting on nobody. The column is left as it was: a mouse that comes back
  gets its focus back with it.
  """
  @spec focus() :: String.t() | nil
  def focus do
    with %House{focus: id} when is_binary(id) <- Repo.one(from(h in House, limit: 1)),
         %Mouse{died_at: nil, removed_at: nil} <- Repo.get(Mouse, id) do
      id
    else
      _ -> nil
    end
  end

  @doc """
  Focus this house on one mouse, or on none. One per house: setting it again
  replaces it. The row is the same one the main session is recorded on, made
  here if `whiska start` has not made it yet.
  """
  @spec set_focus(String.t() | nil) :: :ok
  def set_focus(mouse_id) do
    case Repo.one(from(h in House, limit: 1)) do
      nil -> %House{} |> Ecto.Changeset.change(%{focus: mouse_id}) |> Repo.insert!()
      house -> house |> Ecto.Changeset.change(%{focus: mouse_id}) |> Repo.update!()
    end

    :ok
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

  A finished line goes ahead of the queue once the one delivery slot is free,
  and never holds it (ADR-0008, note of 2026-10-06). It is read apart from
  `next_open/0` for that reason.
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
  Every question nothing can act on and nothing answered, oldest first, with
  its mouse.

  Its mouse died (ADR-0026) or its worktree is gone (ADR-0036), and its branch
  never landed — one that did is `settled` instead (ADR-0064). Kept forever
  (ADR-0007), never delivered, and shown apart from what the person can still
  answer: `whiska questions` lists them under their own heading and the main
  checkout's sidebar line counts them, `◌ n orphaned`.
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
  The answers still to be handed over, oldest first: answered, not taken, and
  the newest question its mouse has asked. A mouse that asked again has moved
  past the answer, so handing it over now would be the mismatch ADR-0005
  exists to stop. At most one per mouse.
  """
  @spec chased() :: [Question.t()]
  def chased do
    latest =
      from(q in Question, group_by: q.mouse_id, select: {q.mouse_id, max(q.id)})
      |> Repo.all()
      |> Map.new()

    from(q in Question,
      where: q.status == "answered" and is_nil(q.taken_at),
      order_by: q.id
    )
    |> Repo.all()
    |> Enum.filter(&(Map.get(latest, &1.mouse_id) == &1.id))
  end

  @spec chased(String.t()) :: [Question.t()]
  def chased(mouse_id), do: Enum.filter(chased(), &(&1.mouse_id == mouse_id))

  @doc """
  The chased answers the owl gave up ringing for: waiting on the person now,
  who can hand one over by typing anything into its mouse's pane — so only a
  live mouse's, since a dead one has no pane to type into (ADR-0057's reading
  of what may wait on the person), and not a landed one's, whose merge was the
  answer (ADR-0064). With their mice, as `questions/0` has them.
  """
  @spec not_taken() :: [Question.t()]
  def not_taken do
    alive = MapSet.new(Enum.reject(alive_mice(), & &1.landed_at), & &1.mouse_id)

    chased()
    |> Enum.filter(&(&1.stale_at && MapSet.member?(alive, &1.mouse_id)))
    |> Repo.preload(:mouse)
  end

  @doc "Stamp answers as handed over to their mouse's session."
  @spec take([integer()], DateTime.t()) :: {:ok, non_neg_integer()}
  def take(ids, at) do
    {n, _} =
      Repo.update_all(
        from(q in Question, where: q.id in ^ids and is_nil(q.taken_at)),
        set: [taken_at: DateTime.truncate(at, :second)]
      )

    {:ok, n}
  end

  @doc "Stamp the doorbell `reply` rang. It is not one of the owl's rings."
  @spec rung(integer(), DateTime.t()) :: {:ok, Question.t()} | {:error, term()}
  def rung(id, at), do: stamp_question(id, rung_at: DateTime.truncate(at, :second))

  @doc "Set the owl's ring count and its last ring, or put them back after a refusal."
  @spec set_ring(integer(), DateTime.t() | nil, non_neg_integer()) ::
          {:ok, Question.t()} | {:error, term()}
  def set_ring(id, at, rings) do
    stamp_question(id, rung_at: at && DateTime.truncate(at, :second), rings: rings)
  end

  @doc "Stamp an answer the owl gave up ringing for."
  @spec mark_not_taken(integer(), DateTime.t()) :: {:ok, Question.t()} | {:error, term()}
  def mark_not_taken(id, at), do: stamp_question(id, stale_at: DateTime.truncate(at, :second))

  defp stamp_question(id, attrs) do
    case Repo.get(Question, id) do
      nil -> {:error, :no_such_question}
      q -> update_status(q, Map.new(attrs))
    end
  end

  @doc """
  Close a question by hand, with no answer. Open, sent, orphaned or settled: an
  orphaned question's answer went to its dead mouse's worktree some other way,
  and a settled one the branch answered can still be put right by hand.
  """
  @spec close_question(integer()) ::
          {:ok, Question.t()} | {:error, :no_such_question | :not_answerable | Ecto.Changeset.t()}
  def close_question(id), do: settle(id, %{status: "closed"}, @waiting ++ ~w(orphaned settled))

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
