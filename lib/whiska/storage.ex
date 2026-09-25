defmodule Whiska.Storage do
  @moduledoc """
  Opening this house's database, for the length of one CLI invocation.

  v0.0.1 is not the owl (ADR-0030): there is no supervision tree and nothing stays
  open. Every hook invocation opens the SQLite file, migrates it if needed, makes
  its decision and exits. The file itself is permanent — a house exists from the
  first invocation onwards and is never destroyed (ADR-0003, ADR-0007).

  The database sits under the **main checkout's** `.git/`, which every worktree
  shares, so all of a repo's mice land in one house rather than one per worktree.
  Being inside `.git/` also means it is gitignored by construction.
  """

  import Ecto.Query, only: [from: 2]

  alias Whiska.Repo
  alias Whiska.Schema.Mouse

  @migrations [{1, Whiska.Migrations.V001CreateMiceAndQuestions}]

  @doc "Where this repo's house lives."
  @spec database_path(Path.t()) :: Path.t()
  def database_path(main_checkout), do: Path.join(main_checkout, ".git/whiska/whiska.db")

  @doc """
  Open the house, creating and migrating it if this is its first invocation.
  """
  @spec open(Path.t()) :: {:ok, pid()} | {:error, term()}
  def open(main_checkout) do
    path = database_path(main_checkout)
    File.mkdir_p!(Path.dirname(path))

    # An escript cannot ship SQLite's native library inside itself; see
    # Whiska.BundledNIF for the whole story. Has to happen before anything
    # touches Exqlite, since the NIF loads when its module first loads.

    with {:ok, _} <- Whiska.BundledNIF.ensure_loadable(),
         {:ok, _} <- Application.ensure_all_started(:ecto_sql),
         {:ok, _} <- Application.ensure_all_started(:ecto_sqlite3),
         {:ok, pid} <- Repo.start_link(repo_opts(path)) do
      migrate()
      {:ok, pid}
    end
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

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  @doc false
  def all(schema), do: Repo.all(from(s in schema, order_by: s.mouse_id))
end
