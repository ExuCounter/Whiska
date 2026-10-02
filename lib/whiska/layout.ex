defmodule Whiska.Layout do
  @moduledoc """
  Where this invocation is, worked out from the on-disk layout alone.

  `spawn-worktree` lays every worktree out at `<main-checkout>/worktrees/<branch>/`,
  and ADR-0030 says to lean on exactly that rather than on `git worktree list`. So
  the derivation starts structurally: walk up from the working directory until an
  ancestor's parent directory is named `worktrees`. That ancestor's parent is the
  container, and the container's parent is the main checkout.

  A branch name can carry slashes, and git nests those on disk — `feat/csv-data-page`
  lands at `worktrees/feat/csv-data-page`, with `worktrees/feat` an ordinary
  directory owning nothing. Nothing about the shape of the tree says where the
  branch name ends, so the worktree root is the deepest directory between the
  container and the working directory that is a checkout of its own, recognised by
  the `.git` file git writes into every linked worktree — the one pointing into the
  main checkout's own `.git/worktrees/`, which is what tells a linked worktree apart
  from a submodule carrying a `.git` file of the same shape. The branch label is
  then the root's path relative to the container, so it reads back as
  `feat/csv-data-page`.

  **A folder under the container that is no checkout of its own is not a worktree**
  (ADR-0030's note, rewritten 2026-10-02). git answers the question directly, and
  the answer does not change as the folder's children come and go, so a session
  sitting in `worktrees/feat` is nobody rather than a mouse called `feat`.
  `unplaced/1` is that same folder read for containment alone: it carries the main
  checkout, and `Whiska.Rule.MainCheckout` denies a write into it from there
  (ADR-0013). Identity is never minted from it.

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
    cwd = Path.expand(cwd)

    case innermost_candidate(cwd) do
      nil -> {:error, :not_in_worktree}
      candidate -> from_candidate(candidate, cwd) || {:error, :not_in_worktree}
    end
  end

  # The innermost folder whose parent is the container, and the only one ever
  # considered: a nested layout belongs to the container it sits in, so a folder
  # that turns out to be no worktree of that one is nobody rather than a mouse
  # of the container above it.
  defp innermost_candidate(cwd) do
    cwd
    |> ancestors()
    |> Enum.find(&(&1 |> Path.dirname() |> Path.basename() == @container))
  end

  @doc """
  The folder a directory sits in when it is under a `worktrees/` container but
  in no worktree of it.

  For containment only (ADR-0013): `worktree_root` is that folder, so a write
  below it is left alone and one into the main checkout is denied, and
  `branch_label` is `nil` because there is no branch and no mouse here. A
  directory that resolves to a real worktree is not this, and neither is the
  container itself or anywhere outside one.
  """
  @spec unplaced(Path.t()) :: {:ok, t()} | {:error, :not_in_worktree}
  def unplaced(cwd) do
    cwd = Path.expand(cwd)

    with {:error, :not_in_worktree} <- resolve(cwd),
         candidate when is_binary(candidate) <- innermost_candidate(cwd) do
      {:ok,
       %__MODULE__{
         worktree_root: candidate,
         main_checkout: candidate |> Path.dirname() |> Path.dirname(),
         branch_label: nil
       }}
    else
      _ -> {:error, :not_in_worktree}
    end
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

  defp from_candidate(candidate, cwd) do
    container = Path.dirname(candidate)

    case deepest_checkout(candidate, cwd) do
      nil ->
        nil

      root ->
        {:ok,
         %__MODULE__{
           worktree_root: root,
           main_checkout: Path.dirname(container),
           branch_label: Path.relative_to(root, container)
         }}
    end
  end

  # Innermost first, and never above `shallowest`, so a sibling branch's folder
  # cannot be picked and the container itself is never considered. Nothing that
  # is a checkout of its own means there is no worktree here at all.
  defp deepest_checkout(shallowest, cwd) do
    cwd
    |> ancestors()
    |> Enum.take_while(&(&1 != Path.dirname(shallowest)))
    |> Enum.find(&checkout?/1)
  end

  # A submodule's `.git` file has the same shape and points into `.git/modules/`,
  # so the gitdir is read rather than only sniffed for.
  defp checkout?(dir) do
    case File.read(Path.join(dir, ".git")) do
      {:ok, "gitdir:" <> gitdir} -> linked_worktree?(String.trim(gitdir), dir)
      _ -> false
    end
  end

  defp linked_worktree?(gitdir, dir) do
    gitdir
    |> Path.expand(dir)
    |> Path.split()
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.any?(&(&1 == [".git", "worktrees"]))
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
