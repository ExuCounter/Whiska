defmodule Whiska.Git do
  @moduledoc """
  The local git questions behind cleanup (ADR-0061), and what a finished branch
  holds for `whiska show` (ADR-0074).

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
  The main checkout a directory sits in: the top folder of a checkout whose own
  git directory is the shared one, which is never true of a linked worktree.

  `{:error, :linked_worktree}` inside a linked worktree, `{:error, :submodule}`
  inside a submodule, whose own git directory sits in its parent's `.git/modules/`,
  and git's own error anywhere that is no checkout at all.
  """
  @spec main_checkout(Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def main_checkout(dir) do
    args = [
      "rev-parse",
      "--path-format=absolute",
      "--git-dir",
      "--git-common-dir",
      "--show-toplevel"
    ]

    # The last three lines: stderr shares the output, so a warning git prints
    # on the way to succeeding sits above them.
    with {:ok, out} <- git(dir, args) do
      case out |> String.split("\n") |> Enum.take(-3) do
        [same, same, top] ->
          if same == Path.join(top, ".git"), do: {:ok, top}, else: {:error, :submodule}

        [_git_dir, _common, _top] ->
          {:error, :linked_worktree}

        _ ->
          {:error, {:unexpected_output, out}}
      end
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
    with {:ok, head} <- head(worktree), do: ancestor?(checkout, head, base)
  end

  @doc "The commit a worktree is sitting on, detached head included."
  @spec head(Path.t()) :: {:ok, String.t()} | {:error, term()}
  def head(worktree), do: git(worktree, ["rev-parse", "HEAD"])

  @doc """
  The commit a branch points at, by name.

  The only way left to ask anything about a mouse's work once its worktree has
  gone (ADR-0064). A branch nobody carries any more is `{:error,
  :no_such_branch}`, never a guess.
  """
  @spec branch_head(Path.t(), branch()) :: {:ok, String.t()} | {:error, term()}
  def branch_head(checkout, branch) do
    case run(checkout, ["rev-parse", "--verify", "--quiet", "refs/heads/" <> branch]) do
      {out, 0} -> {:ok, String.trim(out)}
      _ -> {:error, :no_such_branch}
    end
  end

  @doc """
  How many commits a branch carries beyond the base, merges not counted — all
  that is left to say about a mouse's work once its worktree has gone.
  """
  @spec ahead(Path.t(), branch()) :: {:ok, non_neg_integer()} | {:error, term()}
  def ahead(checkout, branch) do
    with {:ok, base} <- base(checkout),
         true <- plain_name?(base) || {:error, :unsafe_base},
         {:ok, count} <-
           git(checkout, [
             "rev-list",
             "--count",
             "--no-merges",
             "refs/heads/#{base}..refs/heads/#{branch}"
           ]),
         {n, ""} <- Integer.parse(count) do
      {:ok, n}
    else
      {:error, _} = error -> error
      _unparsed -> {:error, :unreadable}
    end
  end

  @doc """
  Is this commit an ancestor of the base branch — has the work landed at all?

  ADR-0061's first precondition, which is also true of a branch cut an hour ago
  that carries nothing: a commit is its own ancestor. `reached_by_merge?/3` is
  what tells the two apart.
  """
  @spec ancestor?(Path.t(), String.t(), branch()) :: {:ok, boolean()} | {:error, term()}
  def ancestor?(checkout, head, base) do
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

  @doc """
  Did the base reach this commit through a merge, rather than simply walking
  past it?

  The base's own first-parent line is where a branch sits that has done nothing
  yet — cut off the base and never moved — and sitting there is not landing
  (ADR-0064). A branch merged with a merge commit hangs off that line as a
  second parent, so its head is not on it.

  Asked by walking the line back as far as this commit and checking what is
  there, which is two cheap commands and no history to read. A branch
  fast-forwarded into the base is on the line like any other and reads as no
  landing: the conservative answer, since nothing distinguishes it afterwards
  from a branch that never moved.
  """
  @spec reached_by_merge?(Path.t(), String.t(), branch()) :: {:ok, boolean()} | {:error, term()}
  def reached_by_merge?(checkout, head, base) do
    with {:ok, base_ref} <- base_ref(checkout, base),
         {:ok, steps} <-
           git(checkout, ["rev-list", "--first-parent", "--count", "#{head}..#{base_ref}"]),
         {:ok, reached} <- git(checkout, ["rev-parse", "#{base_ref}~#{steps}"]) do
      {:ok, reached != head}
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

  @doc """
  What a finished branch holds: its own commits beyond the base, counted as
  Land here lists them — merges from the base skipped — and the paths its
  worktree has not committed, untracked ones included, as git lists them.

  Anything git will not say plainly is an error, never an empty branch: a
  worktree that is not there (`:no_worktree`), one moved off `branch`
  (`:off_branch`), a base whose name is not plain (`:unsafe_base`), or output
  with a warning in it. The finished picker takes nothing for "nothing to land".
  """
  @spec on_branch(Path.t(), Path.t(), branch()) ::
          {:ok, %{base: branch(), ahead: non_neg_integer(), uncommitted: [String.t()]}}
          | {:error, term()}
  def on_branch(checkout, worktree, branch) do
    with true <- File.dir?(worktree) || {:error, :no_worktree},
         {:ok, ^branch} <- head_branch(worktree) |> off_branch(),
         {:ok, base} <- base(checkout),
         true <- plain_name?(base) || {:error, :unsafe_base},
         range = "refs/heads/#{base}..refs/heads/#{branch}",
         {:ok, count} <- git(checkout, ["rev-list", "--count", "--no-merges", range]),
         {ahead, ""} <- Integer.parse(count),
         {:ok, uncommitted} <- uncommitted(worktree) do
      {:ok, %{base: base, ahead: ahead, uncommitted: uncommitted}}
    else
      {:ok, _other_branch} -> {:error, :off_branch}
      {:error, _} = error -> error
      _unparsed_count -> {:error, :unreadable}
    end
  end

  defp off_branch({:error, :detached}), do: {:error, :off_branch}
  defp off_branch(head), do: head

  # The base is printed for the main session, which builds git commands from
  # it; a name with anything else in it is a name a mouse chose.
  defp plain_name?(name), do: Regex.match?(~r/\A[A-Za-z0-9._\/][A-Za-z0-9._\/-]*\z/, name)

  # `-z` keeps each path whole and unquoted; a rename or copy carries its
  # source as the next field, which is not a second uncommitted path. Every
  # untracked file is listed whatever the person's `status.showUntrackedFiles`
  # says, and no optional lock is taken on an index a session may be using.
  defp uncommitted(worktree) do
    args = ["--no-optional-locks", "status", "--porcelain", "-z", "--untracked-files=all"]

    case run(worktree, args) do
      {out, 0} -> paths(String.split(out, "\0", trim: true), [])
      {out, code} -> {:error, {code, String.trim(out)}}
    end
  end

  defp paths([<<x, y, ?\s, path::binary>>, _source | rest], acc)
       when x in [?R, ?C] or y in [?R, ?C],
       do: paths(rest, [path | acc])

  defp paths([<<_xy::binary-size(2), ?\s, path::binary>> | rest], acc),
    do: paths(rest, [path | acc])

  defp paths([], acc), do: {:ok, Enum.reverse(acc)}
  defp paths([_warning | _rest], _acc), do: {:error, :unreadable}

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
