defmodule Whiska.Doorstep do
  @moduledoc """
  Where a mouse leaves a question for the owl (ADR-0036).

  A directory in the house — `<main-checkout>/.git/whiska/doorstep/`, beside the
  database — holding one file per entry the owl has not collected yet. Every
  finished turn is written here: by the owl when it answers the mouse's `Stop`
  hook, by the escript when it does not, so whether the owl is awake changes
  nothing about what is left (ADR-0036). Being in the house
  rather than the worktree is what keeps an entry alive through `whiska drop`.

  Three rules shape everything here:

  - **Writes are atomic.** An entry is written to a `.tmp` name and renamed into
    place, so the owl never reads half a file. `waiting/1` ignores `.tmp` files.
  - **A held entry is not waiting.** A marked stop whose mouse still has a
    subagent out is written beside the others under `.held`, and nothing that
    reads the doorstep counts it: `waiting/1` and `count_waiting/1` see `.json`
    only. The mouse's next stop settles it, or the owl releases it — renames it
    to `.json`, which is one atomic step — once no subagent of the mouse is out and
    the mouse is idle (ADR-0052).
  - **Collection removes the entry** (ADR-0007). The question's row in the house
    is the history, so a collected entry is deleted once recorded. That is also
    what lets the statusline count what is waiting straight off disk when the
    owl is down (ADR-0048): the waiting entries are exactly the `.json` files.
  """

  alias Whiska.Doorstep.Entry

  @dir ".git/whiska/doorstep"
  @ext ".json"
  # What an older owl renamed collected entries to; only ever swept now.
  @legacy ".collected"
  @held ".held"

  @doc "This house's doorstep."
  @spec path(Path.t()) :: Path.t()
  def path(main_checkout), do: Path.join(main_checkout, @dir)

  @doc """
  Leave an entry on the doorstep. Returns the path of the file written.

  The file name sorts by time, then by mouse, then by a random tail so two
  entries from one mouse in the same second cannot collide.
  """
  @spec leave(Path.t(), Entry.t()) :: {:ok, Path.t()} | {:error, File.posix()}
  def leave(main_checkout, %Entry{} = entry), do: write(main_checkout, entry, @ext)

  @doc """
  Leave an entry held: written, but not waiting (ADR-0052). A mouse has one held
  entry at a time, so a newer one replaces the older.
  """
  @spec hold(Path.t(), Entry.t()) :: {:ok, Path.t()} | {:error, File.posix()}
  def hold(main_checkout, %Entry{} = entry) do
    older = Enum.map(held(main_checkout), fn {file, _entry} -> file end)

    with {:ok, _file} = written <- write(main_checkout, entry, @held) do
      _ = drop_held(main_checkout, entry.mouse_id, older)
      written
    end
  end

  defp write(main_checkout, entry, ext) do
    dir = path(main_checkout)
    file = Path.join(dir, filename(entry, ext))
    tmp = file <> ".tmp"

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(tmp, Entry.encode(entry)),
         :ok <- File.rename(tmp, file) do
      {:ok, file}
    end
  end

  defp filename(%Entry{} = entry, ext) do
    stamp = entry.stamped_at |> DateTime.to_unix(:millisecond) |> Integer.to_string()
    tail = 4 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    "#{stamp}-#{safe(entry.mouse_id)}-#{tail}#{ext}"
  end

  defp safe(id), do: String.replace(id, ~r/[^A-Za-z0-9_-]/, "_")

  @doc """
  Every uncollected entry, oldest first, as `{file, entry}`.

  A file that will not parse is skipped and left exactly where it is: it is
  somebody's evidence, and collection deletes only what it recorded.
  """
  @spec waiting(Path.t()) :: [{Path.t(), Entry.t()}]
  def waiting(main_checkout), do: entries(main_checkout, @ext)

  @doc """
  Every held entry, oldest first, as `{file, entry}` (`hold/2`). A file that will
  not parse is skipped and left where it is, as in `waiting/1`.
  """
  @spec held(Path.t()) :: [{Path.t(), Entry.t()}]
  def held(main_checkout), do: entries(main_checkout, @held)

  @doc """
  Make a held entry waiting: rename it to `.json`, atomically, keeping its name's
  stamp so it sorts where it was left.
  """
  @spec release(Path.t()) :: {:ok, Path.t()} | {:error, File.posix()}
  def release(file) do
    released = Path.rootname(file, @held) <> @ext

    with :ok <- File.rename(file, released), do: {:ok, released}
  end

  @doc "Remove a mouse's held entry, which a stop of its own has superseded. How many went."
  @spec drop_held(Path.t(), String.t(), [Path.t()] | :all) :: non_neg_integer()
  def drop_held(main_checkout, mouse_id, only \\ :all) do
    main_checkout
    |> held()
    |> Enum.filter(fn {file, entry} ->
      entry.mouse_id == mouse_id and (only == :all or file in only)
    end)
    |> Enum.count(fn {file, _entry} -> File.rm(file) == :ok end)
  end

  defp entries(main_checkout, ext) do
    dir = path(main_checkout)

    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.ends_with?(&1, ext))
        |> Enum.sort()
        |> Enum.flat_map(fn name ->
          file = Path.join(dir, name)

          with {:ok, raw} <- File.read(file),
               {:ok, entry} <- Entry.decode(raw) do
            [{file, entry}]
          else
            _ -> []
          end
        end)

      {:error, _} ->
        []
    end
  end

  @doc "How many entries are waiting — cheap, no parsing, for the statusline."
  @spec count_waiting(Path.t()) :: non_neg_integer()
  def count_waiting(main_checkout) do
    case File.ls(path(main_checkout)) do
      {:ok, names} -> Enum.count(names, &String.ends_with?(&1, @ext))
      {:error, _} -> 0
    end
  end

  @doc """
  Remove an entry the owl has recorded. The row is the history (ADR-0007).
  An entry already gone counts as removed.
  """
  @spec collected(Path.t()) :: :ok | {:error, File.posix()}
  def collected(file) do
    case File.rm(file) do
      # Already gone is collected: holding the entry back would record it twice.
      {:error, :enoent} -> :ok
      other -> other
    end
  end

  @doc """
  Remove the `.collected` files an older owl kept. Returns how many went.
  """
  @spec sweep_collected(Path.t()) :: non_neg_integer()
  def sweep_collected(main_checkout) do
    dir = path(main_checkout)

    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.ends_with?(&1, @legacy))
        |> Enum.count(&(File.rm(Path.join(dir, &1)) == :ok))

      {:error, _} ->
        0
    end
  end
end
