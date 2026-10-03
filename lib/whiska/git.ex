defmodule Whiska.Git do
  @moduledoc """
  The local git questions behind cleanup (ADR-0061).

  Whether a branch has landed, a worktree is clean and every commit is on a
  remote are questions git answers on this machine, with no network, no forge
  and no credentials. They are the four preconditions that make taking a
  worktree down safe, so each one is asked separately and each one can answer
  "I do not know".

  **Unknown is never permission.** Every function returns `{:error, reason}`
  rather than a guess when git will not say — a detached head, an unreadable
  git directory, a base branch that cannot be resolved — and `Whiska.Cleanup`
  treats any of them as "leave it alone".

  The two functions that change something, `remove_worktree/2` and
  `delete_branch/2`, never force. `git worktree remove` without `--force` and
  `git branch -d` rather than `-D` refuse on exactly what the checks above are
  meant to have ruled out, which makes them a second, independent opinion.
  """

  @base_names ~w(main master)

  @typedoc "A branch name, with no `refs/` prefix and no remote in front of it."
  @type branch :: String.t()

  @doc """
  The base branch's name — what a worktree's branch has to have landed in.

  `origin/HEAD` is the authority, since it is what the forge itself calls the
  default branch. With no remote to ask, exactly one local `main` or `master`
  is taken as the answer; anything else is `:ambiguous_base`, which means do
  nothing.
  """
  @spec base(Path.t()) :: {:ok, branch()} | {:error, term()}
  def base(checkout) do
    with {:ok, _} <- git(checkout, ["rev-parse", "--git-dir"]) do
      case git(checkout, ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"]) do
        {:ok, "origin/" <> name} -> {:ok, name}
        _ -> local_base(checkout)
      end
    end
  end

  defp local_base(checkout) do
    case git(checkout, ["branch", "--format=%(refname:short)", "--list" | @base_names]) do
      {:ok, out} ->
        case String.split(out, "\n", trim: true) do
          [one] -> {:ok, one}
          _ -> {:error, :ambiguous_base}
        end

      {:error, _} ->
        {:error, :ambiguous_base}
    end
  end

  @doc """
  The branch a worktree has checked out.

  A detached head is `{:error, :detached}` and never a branch name: there is
  nothing to check for merged-ness and nothing to delete afterwards.
  """
  @spec head_branch(Path.t()) :: {:ok, branch()} | {:error, term()}
  def head_branch(worktree) do
    case git(worktree, ["symbolic-ref", "--short", "HEAD"]) do
      {:ok, branch} ->
        {:ok, branch}

      {:error, reason} ->
        case git(worktree, ["rev-parse", "--git-dir"]) do
          {:ok, _} -> {:error, :detached}
          {:error, _} -> {:error, reason}
        end
    end
  end

  @doc """
  Has this worktree's head landed in the base branch?

  The local base branch is preferred and its remote-tracking branch is the
  fallback, so a base checked out nowhere still answers. A base that resolves
  to neither is an error, not a `false`.
  """
  @spec merged?(Path.t(), Path.t(), branch()) :: {:ok, boolean()} | {:error, term()}
  def merged?(checkout, worktree, base) do
    with {:ok, head} <- git(worktree, ["rev-parse", "HEAD"]), do: ancestor?(checkout, head, base)
  end

  @doc """
  Has this branch landed in the base branch?

  The same question as `merged?/3` asked of a branch name rather than a
  worktree, which is the only way left to ask it once the worktree has gone
  (ADR-0063). A branch nobody carries any more is `{:error, :no_such_branch}`,
  never a `false`: it is unknown, not a refusal.
  """
  @spec branch_merged?(Path.t(), branch(), branch()) :: {:ok, boolean()} | {:error, term()}
  def branch_merged?(checkout, branch, base) do
    case run(checkout, ["rev-parse", "--verify", "--quiet", "refs/heads/" <> branch]) do
      {out, 0} -> ancestor?(checkout, String.trim(out), base)
      _ -> {:error, :no_such_branch}
    end
  end

  defp ancestor?(checkout, head, base) do
    with {:ok, base_ref} <- base_ref(checkout, base) do
      case run(checkout, ["merge-base", "--is-ancestor", head, base_ref]) do
        {_, 0} -> {:ok, true}
        {_, 1} -> {:ok, false}
        {out, code} -> {:error, {code, out}}
      end
    end
  end

  defp base_ref(checkout, base) do
    ["refs/heads/#{base}", "refs/remotes/origin/#{base}"]
    |> Enum.find(&match?({_, 0}, run(checkout, ["rev-parse", "--verify", "--quiet", &1])))
    |> case do
      nil -> {:error, {:no_base_ref, base}}
      ref -> {:ok, ref}
    end
  end

  @doc "Is there nothing in this worktree left to save? Untracked files count as something."
  @spec clean?(Path.t()) :: {:ok, boolean()} | {:error, term()}
  def clean?(worktree) do
    with {:ok, out} <- git(worktree, ["status", "--porcelain"]), do: {:ok, out == ""}
  end

  @doc """
  Is any commit on this branch absent from every remote?

  One commit is enough to answer, and asking for one keeps the cost flat: with
  no remote-tracking branch covering it, `--not --remotes` excludes nothing and
  git would otherwise walk and print the whole history for a boolean.
  """
  @spec unpushed?(Path.t(), branch()) :: {:ok, boolean()} | {:error, term()}
  def unpushed?(worktree, branch) do
    args = ["log", "--max-count=1", "--format=%H", branch, "--not", "--remotes", "--"]
    with {:ok, out} <- git(worktree, args), do: {:ok, out != ""}
  end

  @doc "Remove a worktree, never forcing. Git refuses a dirty one, and that refusal stands."
  @spec remove_worktree(Path.t(), Path.t()) :: :ok | {:error, term()}
  def remove_worktree(checkout, worktree) do
    with {:ok, _} <- git(checkout, ["worktree", "remove", worktree]), do: :ok
  end

  @doc "Delete a branch with `-d`, never `-D`. Git refuses an unmerged one, and so do we."
  @spec delete_branch(Path.t(), branch()) :: :ok | {:error, term()}
  def delete_branch(checkout, branch) do
    with {:ok, _} <- git(checkout, ["branch", "-d", branch]), do: :ok
  end

  @doc "Forget the admin records of worktrees whose folders have gone."
  @spec prune_worktrees(Path.t()) :: :ok | {:error, term()}
  def prune_worktrees(checkout) do
    with {:ok, _} <- git(checkout, ["worktree", "prune"]), do: :ok
  end

  defp git(dir, args) do
    case run(dir, args) do
      {out, 0} -> {:ok, String.trim(out)}
      {out, code} -> {:error, {code, String.trim(out)}}
    end
  end

  defp run(dir, args) do
    if File.dir?(dir) do
      System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    else
      {"no such directory: #{dir}", 128}
    end
  end
end
