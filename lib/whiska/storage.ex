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

  alias Whiska.Repo
  alias Whiska.Schema.Mouse
  alias Whiska.Schema.Question

  @migrations [
    {1, Whiska.Migrations.V001CreateMiceAndQuestions},
    {2, Whiska.Migrations.V002OwlCollection}
  ]

  @modes ~w(build sniff)

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

  @doc "Every mouse not marked dead, oldest first."
  @spec alive_mice() :: [Mouse.t()]
  def alive_mice do
    Repo.all(from(m in Mouse, where: is_nil(m.died_at), order_by: m.created_at))
  end

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

  The row stays (ADR-0007). Its still-open questions cascade to `orphaned`
  rather than sitting open forever; anything already sent, answered or closed
  is history and is left alone. Marking an already-dead mouse changes nothing.
  """
  @spec mark_dead(String.t()) :: {:ok, Mouse.t()} | {:error, :no_such_mouse | Ecto.Changeset.t()}
  def mark_dead(mouse_id) do
    case Repo.get(Mouse, mouse_id) do
      nil ->
        {:error, :no_such_mouse}

      %Mouse{died_at: %DateTime{}} = mouse ->
        {:ok, mouse}

      mouse ->
        Repo.transaction(fn ->
          Repo.update_all(
            from(q in Question, where: q.mouse_id == ^mouse_id and q.status == "open"),
            set: [status: "orphaned"]
          )

          mouse
          |> Ecto.Changeset.change(%{died_at: now()})
          |> Repo.update!()
        end)
    end
  end

  @doc """
  Record a question the owl collected from the doorstep (ADR-0036).

  `status` defaults to `open`; a `done` report passes `closed` so it is never
  delivered (ADR-0009). Kind and status are checked against the lists on
  `Whiska.Schema.Question`, so nothing unclassifiable is stored.
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

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  @doc false
  def all(schema), do: Repo.all(from(s in schema, order_by: s.mouse_id))
end
