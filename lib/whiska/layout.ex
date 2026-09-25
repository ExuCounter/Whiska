defmodule Whiska.Layout do
  @moduledoc """
  Where this invocation is, worked out from the on-disk layout alone.

  `spawn-worktree` lays every worktree out at `<main-checkout>/worktrees/<branch>/`,
  and ADR-0030 says to lean on exactly that rather than on git internals — no
  `git worktree list`, no `.git` file-vs-directory probing. So the derivation is
  purely structural: walk up from the working directory until an ancestor's parent
  directory is named `worktrees`. That ancestor is the worktree root; its
  grandparent is the main checkout.

  Re-derived on every invocation rather than recorded anywhere. That keeps the
  marker file a bare opaque id exactly as ADR-0002 describes it ("no parsing
  involved") and leaves nothing to migrate. If a worktree outside this layout ever
  becomes real, recording the path in the marker file is a small upgrade then.
  """

  @container "worktrees"
  @max_link_hops 16

  defstruct [:worktree_root, :main_checkout, :branch_label]

  @type t :: %__MODULE__{
          worktree_root: Path.t(),
          main_checkout: Path.t(),
          branch_label: String.t()
        }

  @doc """
  Resolve the layout for a working directory.

  Returns `{:error, :not_in_worktree}` when the directory is not inside a
  `worktrees/<branch>/` folder — which includes the main checkout itself and the
  `worktrees/` container directory.
  """
  @spec resolve(Path.t()) :: {:ok, t()} | {:error, :not_in_worktree}
  def resolve(cwd) do
    cwd
    |> Path.expand()
    |> ancestors()
    |> Enum.find_value({:error, :not_in_worktree}, &from_candidate/1)
  end

  # Every path from `path` up to the filesystem root, innermost first. Innermost
  # first is what makes a nested layout resolve to the *inner* worktree.
  defp ancestors(path) do
    Stream.unfold(path, fn
      nil -> nil
      "/" -> {"/", nil}
      current -> {current, Path.dirname(current)}
    end)
  end

  defp from_candidate(candidate) do
    container = Path.dirname(candidate)

    if Path.basename(container) == @container do
      {:ok,
       %__MODULE__{
         worktree_root: candidate,
         main_checkout: Path.dirname(container),
         branch_label: Path.basename(candidate)
       }}
    end
  end

  @doc """
  Is `path` the directory `dir` itself, or something beneath it?

  Both sides are canonicalised first, so a symlink pointing into the main
  checkout cannot be used to slip past the rule, and compared on path segments,
  so `/a/bb` is not treated as living inside `/a/b`.
  """
  @spec inside?(Path.t(), Path.t()) :: boolean()
  def inside?(path, dir) do
    path_parts = Path.split(canonical(path))
    dir_parts = Path.split(canonical(dir))

    List.starts_with?(path_parts, dir_parts)
  end

  @doc """
  Expand a path and resolve every symlink along it.

  Erlang has no `realpath`, so this walks the path a segment at a time and
  follows any symlink it finds. Segments that do not exist yet — the common case
  for a `Write` creating a new file — are simply kept as-is.
  """
  @spec canonical(Path.t()) :: Path.t()
  def canonical(path), do: canonical(path, @max_link_hops)

  defp canonical(path, hops) do
    path
    |> Path.expand()
    |> Path.split()
    |> Enum.reduce("/", fn segment, resolved ->
      resolved |> Path.join(segment) |> follow(hops)
    end)
  end

  # Depth-limited so a symlink cycle cannot spin forever; on exhaustion we fall
  # back to the unresolved path, which the rule then treats conservatively.
  defp follow(path, 0), do: path

  defp follow(path, hops) do
    case :file.read_link(path) do
      {:ok, target} ->
        target
        |> to_string()
        |> then(fn t -> if absolute?(t), do: t, else: Path.join(Path.dirname(path), t) end)
        |> canonical(hops - 1)

      {:error, _} ->
        path
    end
  end

  defp absolute?(path), do: Path.type(path) == :absolute
end
