defmodule Whiska.Drop do
  @moduledoc """
  `whiska drop`: take a branch's worktree down before it lands, with its herdr
  workspace and its branch, together. The worktree alone would leave a stale
  workspace; the workspace alone, the worktree on disk.

  Work is lost only on `--force`. Without it, a worktree holding files it never
  committed, or a branch holding commits no remote and no base has, is left
  exactly as it is, and the refusal names every commit and file that would go,
  so the person decides on what is actually lost. A base nobody can name is no
  answer either, and refuses the same way (ADR-0061: unknown is never
  permission).

  A landed worktree needs none of this: the owl takes it down (ADR-0061). The
  mouse's record survives, stamped removed and dead, and its questions stay
  readable (ADR-0007).
  """

  alias Whiska.Git
  alias Whiska.Review
  alias Whiska.Schema.Mouse
  alias Whiska.Storage

  @doc """
  Drop `branch` from `main_checkout`, whose house is open. Answers the line for
  the person, or why nothing went.
  """
  @spec run(Path.t(), String.t(), boolean(), %{herdr: module(), socket: Path.t()}) ::
          {:ok, String.t()} | {:error, String.t()}
  def run(main_checkout, branch, force?, via) do
    with {:ok, tree} <- worktree(main_checkout, branch, via),
         :ok <- something_there(main_checkout, branch, tree),
         {:ok, lost} <- lost(main_checkout, branch, tree),
         :ok <- allowed(branch, lost, force?),
         :ok <- remove(main_checkout, tree, lost, via),
         :ok <- delete_branch(main_checkout, branch) do
      Review.remove(main_checkout, branch)
      mark_removed(branch)
      {:ok, "Dropped #{branch}: its worktree, workspace and branch are gone."}
    end
  end

  defp worktree(main_checkout, branch, via) do
    case via.herdr.worktrees(via.socket, main_checkout) do
      {:ok, trees} -> {:ok, Enum.find(trees, &(&1.branch == branch))}
      {:error, reason} -> {:error, "could not ask herdr for worktrees (#{inspect(reason)})."}
    end
  end

  defp something_there(main_checkout, branch, tree) do
    if tree || match?({:ok, _}, Git.branch_head(main_checkout, branch)),
      do: :ok,
      else: {:error, "there is no worktree and no branch called #{branch} here to drop."}
  end

  defp lost(main_checkout, branch, tree) do
    with {:ok, commits} <- commits(main_checkout, branch),
         {:ok, files, dirty?} <- files(main_checkout, tree) do
      {:ok, %{commits: commits, files: files, dirty?: dirty?}}
    end
  end

  defp commits(main_checkout, branch) do
    case Git.unpushed_commits(main_checkout, branch, recorded_base(branch)) do
      {:ok, commits} -> {:ok, commits}
      {:error, _} -> {:ok, :unknown}
    end
  end

  defp files(_main_checkout, nil), do: {:ok, [], false}

  # The hook files a spawn carried in are no work to lose, but they still keep
  # git from removing the worktree unforced.
  defp files(main_checkout, %{path: path}) do
    case Whiska.Land.left(main_checkout, path) do
      {:ok, files, carried} -> {:ok, files, files != [] or carried != []}
      {:error, _} -> {:ok, :unknown, true}
    end
  end

  defp allowed(_branch, _lost, true), do: :ok
  defp allowed(_branch, %{commits: [], files: []}, false), do: :ok

  defp allowed(branch, lost, false) do
    {:error,
     "dropping #{branch} would lose work, so nothing was dropped.\n\n" <>
       commits_lost(lost.commits) <>
       files_lost(lost.files) <> "\n`whiska drop #{branch} --force` drops it anyway."}
  end

  defp commits_lost([]), do: ""
  defp commits_lost(:unknown), do: "Which commits no remote has could not be read.\n"

  defp commits_lost(commits),
    do: "Commits on no remote:\n" <> Enum.map_join(commits, "", &"  #{&1}\n")

  defp files_lost([]), do: ""

  defp files_lost(:unknown),
    do: "Whether the worktree holds uncommitted files could not be read.\n"

  defp files_lost(files),
    do: "Files not committed:\n" <> Enum.map_join(files, "", &"  #{&1}\n")

  defp remove(_main_checkout, nil, _lost, _via), do: :ok

  defp remove(main_checkout, %{path: path, workspace_id: workspace}, lost, via) do
    dirty? = lost.dirty?

    removed =
      cond do
        is_nil(workspace) -> :ok
        dirty? -> via.herdr.force_remove_worktree(via.socket, workspace)
        true -> via.herdr.remove_worktree(via.socket, workspace)
      end

    case removed do
      :ok ->
        git_remove(main_checkout, path, dirty?)

      {:error, reason} ->
        {:error, "herdr could not remove #{path} (#{inspect(reason)}). Nothing else was touched."}
    end
  end

  # herdr closes the workspace and removes the worktree in one call; a worktree
  # it left on disk, or one with no workspace open, is git's to remove.
  defp git_remove(main_checkout, path, dirty?) do
    if File.dir?(path) do
      args = ["worktree", "remove", path] ++ if(dirty?, do: ["--force"], else: [])

      case System.cmd("git", args, cd: main_checkout, stderr_to_stdout: true) do
        {_, 0} -> :ok
        {out, _} -> {:error, "git could not remove #{path}: #{String.trim(out)}"}
      end
    else
      :ok
    end
  end

  defp delete_branch(main_checkout, branch) do
    if match?({:ok, _}, Git.branch_head(main_checkout, branch)) do
      case System.cmd("git", ["branch", "-D", branch], cd: main_checkout, stderr_to_stdout: true) do
        {_, 0} -> :ok
        {out, _} -> {:error, "the worktree is gone, but git kept #{branch}: #{String.trim(out)}"}
      end
    else
      :ok
    end
  end

  defp mark_removed(branch) do
    for %Mouse{branch: ^branch, removed_at: nil, mouse_id: id} <- Storage.current_mice(),
        do: Storage.mark_removed(id)
  end

  defp recorded_base(branch) do
    Mouse
    |> Storage.all()
    |> Enum.filter(&(&1.branch == branch and &1.base))
    |> Enum.max_by(& &1.created_at, DateTime, fn -> nil end)
    |> case do
      %Mouse{base: base} -> base
      nil -> nil
    end
  end
end
