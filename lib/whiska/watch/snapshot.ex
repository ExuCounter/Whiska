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

  @doc "Where a house's board lives."
  @spec path(Path.t()) :: Path.t()
  def path(main_checkout) do
    slug = String.replace(Path.expand(main_checkout), ~r/[^A-Za-z0-9]/, "-")

    Path.join([OpenHouses.home(), "board", slug])
  end

  @doc "Replace a house's board."
  @spec write(Path.t(), String.t()) :: :ok | {:error, term()}
  def write(main_checkout, text) do
    file = path(main_checkout)
    tmp = file <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(file)),
         :ok <- File.write(tmp, text) do
      File.rename(tmp, file)
    end
  end
end
