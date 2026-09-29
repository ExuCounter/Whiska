defmodule Whiska.Watch.Snapshot do
  @moduledoc """
  The board on disk: what the owl writes and the statusline prints (ADR-0051).

  The statusline script is bash and must find this file without starting the
  escript — that startup is the whole cost the snapshot exists to remove — so
  the name is something `tr -c 'A-Za-z0-9' '-'` produces from the main
  checkout's path, and nothing more clever.

  A write replaces the file whole, through a temporary neighbour, so a
  statusline reading it mid-write sees the old board rather than half of the
  new one. A quiet house writes an empty file: the last board must not stay on
  the screen after the mice are gone.
  """

  alias Whiska.OpenHouses

  @doc """
  Where a house's board lives.

  The name is worked out byte by byte, because `tr` is: a main checkout with a
  non-ASCII character in its path would otherwise be spelled one way here and
  another way by the script, and never find its own board.
  """
  @spec path(Path.t()) :: Path.t()
  def path(main_checkout) do
    Path.join([OpenHouses.home(), "board", slug(Path.expand(main_checkout))])
  end

  defp slug(path) do
    for <<byte <- path>>, into: "" do
      if byte in ?A..?Z or byte in ?a..?z or byte in ?0..?9, do: <<byte>>, else: "-"
    end
  end

  @doc """
  Replace a house's board.

  The board is the person's alone — it carries file paths, command excerpts and
  sentences out of their private sessions — so the folder and the file are
  theirs to read and nobody else's. The temporary neighbour is removed before it
  is written, so a symlink planted in its place is replaced rather than followed.
  """
  @spec write(Path.t(), String.t()) :: :ok | {:error, term()}
  def write(main_checkout, text) do
    file = path(main_checkout)
    tmp = file <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(file)),
         :ok <- File.chmod(Path.dirname(file), 0o700),
         _gone <- File.rm(tmp),
         :ok <- File.write(tmp, text, [:exclusive]),
         :ok <- File.chmod(tmp, 0o600) do
      File.rename(tmp, file)
    end
  end
end
