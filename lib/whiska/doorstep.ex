defmodule Whiska.Doorstep do
  @moduledoc """
  Where a mouse leaves a question for the owl (ADR-0036).

  A directory in the house — `<main-checkout>/.git/whiska/doorstep/`, beside the
  database — holding one file per entry the owl has not collected yet. Every
  finished turn is written here: by the owl when it answers the mouse's `Stop`
  hook, by the escript when it does not, so whether the owl is awake changes
  nothing about what is left (ADR-0036, amended). Being in the house
  rather than the worktree is what keeps an entry alive through `drop-worktree`.

  Two rules shape everything here:

  - **Writes are atomic.** An entry is written to a `.tmp` name and renamed into
    place, so the owl never reads half a file. `waiting/1` ignores `.tmp` files.
  - **Collection marks, it never deletes** (ADR-0007). A collected entry is
    renamed to `.collected` in the same directory. That is also what lets the
    statusline count what is waiting straight off disk when the owl is down
    (ADR-0027): the waiting entries are exactly the `.json` files.
  """

  alias Whiska.Doorstep.Entry

  @dir ".git/whiska/doorstep"
  @ext ".json"
  @collected ".collected"

  @doc "This house's doorstep."
  @spec path(Path.t()) :: Path.t()
  def path(main_checkout), do: Path.join(main_checkout, @dir)

  @doc """
  Leave an entry on the doorstep. Returns the path of the file written.

  The file name sorts by time, then by mouse, then by a random tail so two
  entries from one mouse in the same second cannot collide.
  """
  @spec leave(Path.t(), Entry.t()) :: {:ok, Path.t()} | {:error, File.posix()}
  def leave(main_checkout, %Entry{} = entry) do
    dir = path(main_checkout)
    file = Path.join(dir, filename(entry))
    tmp = file <> ".tmp"

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(tmp, Entry.encode(entry)),
         :ok <- File.rename(tmp, file) do
      {:ok, file}
    end
  end

  defp filename(%Entry{} = entry) do
    stamp = entry.stamped_at |> DateTime.to_unix(:millisecond) |> Integer.to_string()
    tail = 4 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    "#{stamp}-#{safe(entry.mouse_id)}-#{tail}#{@ext}"
  end

  defp safe(id), do: String.replace(id, ~r/[^A-Za-z0-9_-]/, "_")

  @doc """
  Every uncollected entry, oldest first, as `{file, entry}`.

  A file that will not parse is skipped and left exactly where it is: it is
  somebody's evidence, and collection never deletes.
  """
  @spec waiting(Path.t()) :: [{Path.t(), Entry.t()}]
  def waiting(main_checkout) do
    dir = path(main_checkout)

    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.ends_with?(&1, @ext))
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
  Mark an entry collected by renaming it in place. Returns the new path.
  """
  @spec mark_collected(Path.t()) :: {:ok, Path.t()} | {:error, File.posix()}
  def mark_collected(file) do
    kept = file <> @collected

    case File.rename(file, kept) do
      :ok -> {:ok, kept}
      {:error, reason} -> {:error, reason}
    end
  end
end
