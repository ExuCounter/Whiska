defmodule Whiska.OpenHouses do
  @moduledoc """
  The owl's record of which houses it has open, on disk (ADR-0039).

  One main checkout per line at `~/.whiska/houses` — the machine-level folder
  ADR-0025 reserves for the global socket. The owl adds a line when it opens a
  house and removes it when it shuts one, so `whiska owl` with no arguments
  can open what was open last time, and the statusline can count the whiskas
  the owl is actually keeping rather than every repo with a house file on disk.

  A crashed or Ctrl-C'd owl leaves the file behind on purpose — that is the
  memory the next `whiska owl` restores from. What stops it lying meanwhile is
  `open/2`: the record is trusted only while an owl is in the process table,
  the probe `Whiska.Owl.pids/0` the doctor and the statusline already share.
  With no owl alive, no house is open, whatever the file says.

  Nothing here creates or destroys a house (ADR-0003); this is about lights on
  or off, and only the owl's own opening and shutting write it. The file is
  plain text so it can be hand-edited until `whiska stop` exists.
  """

  @doc """
  Where the record lives: `houses` under the whiska home, which is the
  `:home` application setting, then `WHISKA_HOME`, then `~/.whiska`.
  """
  @spec path() :: Path.t()
  def path, do: Path.join(home(), "houses")

  defp home do
    Application.get_env(:whiska, :home) ||
      System.get_env("WHISKA_HOME") ||
      Path.join(System.user_home!(), ".whiska")
  end

  @doc "The recorded main checkouts, sorted. No file is no houses."
  @spec read(Path.t()) :: [Path.t()]
  def read(path \\ path()) do
    case File.read(path) do
      {:ok, contents} ->
        contents
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.map(&Path.expand/1)
        |> Enum.uniq()
        |> Enum.sort()

      {:error, _} ->
        []
    end
  end

  @doc """
  The record as anyone but the owl may trust it: what `read/1` says while an
  owl is alive, nothing when none is. `pids` is what `Whiska.Owl.pids/0` found.
  """
  @spec open([pos_integer()], Path.t()) :: [Path.t()]
  def open(pids, path \\ path())
  def open([], _path), do: []
  def open(_pids, path), do: read(path)

  @doc "Record a house as open."
  @spec add(Path.t(), Path.t()) :: :ok | {:error, term()}
  def add(main_checkout, path \\ path()),
    do: write([Path.expand(main_checkout) | read(path)], path)

  @doc "Record a house as shut. Removing one that is not there is fine."
  @spec remove(Path.t(), Path.t()) :: :ok | {:error, term()}
  def remove(main_checkout, path \\ path()) do
    main = Path.expand(main_checkout)
    write(Enum.reject(read(path), &(&1 == main)), path)
  end

  @doc "Replace the record with exactly these houses."
  @spec write([Path.t()], Path.t()) :: :ok | {:error, term()}
  def write(houses, path \\ path()) do
    lines = houses |> Enum.map(&Path.expand/1) |> Enum.uniq() |> Enum.sort()
    tmp = path <> ".tmp-#{System.unique_integer([:positive])}"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp, Enum.map_join(lines, "", &(&1 <> "\n"))) do
      File.rename(tmp, path)
    end
  end
end
