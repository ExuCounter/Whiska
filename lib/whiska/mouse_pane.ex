defmodule Whiska.MousePane do
  @moduledoc """
  What bounds a pane the owl types into on its own: a mouse's pane, found by
  where it sits, in a folder herdr itself calls a worktree of this checkout,
  with nothing half-typed in its prompt box.

  A mouse record's `path` is minted from a doorstep entry, a JSON file anything
  running in this repo can write (ADR-0061), so it is not on its own a
  statement that a folder is a worktree of this house. herdr's `worktree.list`
  is the second opinion (ADR-0067).
  """

  alias Whiska.Delivery.Draft
  alias Whiska.Layout
  alias Whiska.Schema.Mouse

  @doc "The panes running an agent inside this mouse's worktree."
  @spec agent_panes(Mouse.t(), [map()]) :: [map()]
  def agent_panes(%Mouse{path: path}, panes) when is_binary(path) do
    Enum.filter(panes, &(&1.agent != nil and is_binary(&1.cwd) and Layout.inside?(&1.cwd, path)))
  end

  def agent_panes(_no_path, _panes), do: []

  @doc "The folders herdr calls linked worktrees of this checkout, canonical."
  @spec our_worktrees(map()) :: {:ok, MapSet.t(Path.t())} | :unknown
  def our_worktrees(house) do
    case house.herdr.worktrees(house.socket, house.main_checkout) do
      {:ok, worktrees} -> {:ok, MapSet.new(worktrees, &Layout.canonical(&1.path))}
      {:error, _reason} -> :unknown
    end
  end

  @spec ours?(Mouse.t(), MapSet.t(Path.t())) :: boolean()
  def ours?(%Mouse{path: path}, ours), do: MapSet.member?(ours, Layout.canonical(path))

  @doc """
  The prompt box, read exactly as delivery reads the main session's (ADR-0047):
  herdr's idle is the model's word, and a line typed into a box somebody is
  halfway through lands inside what they are writing. A box not on the screen
  at all is the same refusal as a draft (ADR-0047). An unreadable screen is an
  unavailable signal, so it reads as empty.
  """
  @spec box(map(), map()) :: Draft.t()
  def box(pane, house) do
    case house.herdr.read_screen(house.socket, pane.pane_id) do
      {:ok, screen} -> Draft.read(screen)
      {:error, _reason} -> :empty
    end
  end
end
