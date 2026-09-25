defmodule Whiska.Marker do
  @moduledoc """
  The mouse's identity: one opaque id in a hidden file at the worktree root.

  ADR-0002 makes this the single stable key for a mouse. Neither the branch name
  nor the folder path qualifies — branches get renamed casually and folders get
  moved, and neither should break tracking. So the id is opaque, and branch and
  path stay mutable display labels hanging off it.

  ADR-0030 makes the minting lazy: the marker appears on the first hook invocation
  inside a worktree that has none, written by this CLI, so nothing upstream
  (`spawn-worktree`) has to change for this slice.

  The file holds the bare id and nothing else — no JSON, no key/value — so reading
  it stays "no more complex than reading a branch name, and involves no parsing"
  as ADR-0002 puts it. It is gitignored, same as `.herdr-worktree-meta`.
  """

  @filename ".whiska-mouse"

  @doc "Path to the marker file for a worktree root."
  @spec path(Path.t()) :: Path.t()
  def path(worktree_root), do: Path.join(worktree_root, @filename)

  @doc """
  Read this worktree's `mouse_id`, minting and persisting one if it has none.

  An absent, empty, or whitespace-only marker is treated the same way: mint a
  fresh id and write it.
  """
  @spec read_or_mint(Path.t()) :: {:ok, String.t()} | {:error, File.posix()}
  def read_or_mint(worktree_root) do
    file = path(worktree_root)

    case read(file) do
      {:ok, mouse_id} -> {:ok, mouse_id}
      :empty -> mint(file)
    end
  end

  defp read(file) do
    case File.read(file) do
      {:ok, contents} ->
        case String.trim(contents) do
          "" -> :empty
          mouse_id -> {:ok, mouse_id}
        end

      {:error, _} ->
        :empty
    end
  end

  defp mint(file) do
    mouse_id = 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

    case File.write(file, mouse_id <> "\n") do
      :ok -> {:ok, mouse_id}
      {:error, reason} -> {:error, reason}
    end
  end
end
