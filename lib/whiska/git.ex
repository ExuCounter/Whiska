defmodule Whiska.Git do
  @moduledoc """
  The local git questions behind cleanup (ADR-0061), and what a finished branch
  holds for `whiska show` (ADR-0074).

  Whether a branch has landed, a worktree is clean and every commit is on a
  remote are questions git answers on this machine, with no network, no forge
  and no credentials. They are the four preconditions that make taking a
  worktree down safe, so each one is asked separately and each one can answer
  "I do not know". The one call that reaches a remote is `fetch_base/3`, which
  refreshes the copy of the base those questions also read, and can never
  prompt.

  **Unknown is never permission.** Every function returns `{:error, reason}`
  rather than a guess when git will not say — a detached head, an unreadable
  git directory, a base branch that cannot be resolved — and `Whiska.Cleanup`
  treats any of them as "leave it alone".

  The two functions that change something, `remove_worktree/2` and
  `delete_branch/3`, do not force by default. `git worktree remove` without `--force` and
  `git branch -d` rather than `-D` refuse on exactly what the checks above are
  meant to have ruled out, which makes them a second, independent opinion. The
  one exception is a landing `-d` cannot recognise — copies `in_base?/3` has
  found, or work only the fetched copy of the base holds: that branch is
  deleted only while it still points at the commit that was checked.
  """

  @base_names ~w(main master)

  @batch_ssh "ssh -o BatchMode=yes -o ConnectTimeout=20 -o ServerAliveInterval=15 -o ServerAliveCountMax=2"

  @typedoc "A branch name, with no `refs/` prefix and no remote in front of it."
  @type branch :: String.t()

  @typedoc "A base branch by name, or one place it is read, as `landing_refs/2` tags it."
  @type base :: branch() | {:local | :fetched, String.t()}

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

  @doc """
  The branch one mouse's worktree has to have landed in: the base `whiska shape`
  recorded when it was spawned, which is the branch the main checkout was on
  and so the one the worktree was cut from.

  A mouse with no recorded base is read against `base/1`, as before. A recorded
  base that no longer resolves is `{:error, {:base_gone, name}}` and never a
  fall back to the default branch: measuring a staging mouse against `main`
  is the mistake this exists to end (ADR-0061, unknown is never permission).
  """
  @spec base_of(Path.t(), branch() | nil) :: {:ok, branch()} | {:error, term()}
  def base_of(checkout, nil) do
    with {:ok, name} <- base(checkout), do: plain(name)
  end

  def base_of(checkout, recorded) do
    with {:ok, name} <- plain(recorded),
         {:ok, _ref} <- base_ref(checkout, name) do
      {:ok, name}
    else
      {:error, {:no_base_ref, name}} -> {:error, {:base_gone, name}}
      {:error, _} = error -> error
    end
  end

  # The base is printed for a mouse, which builds git commands from it.
  defp plain(name), do: if(plain_name?(name), do: {:ok, name}, else: {:error, :unsafe_base})

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
  @spec ahead(Path.t(), branch(), branch() | nil) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def ahead(checkout, branch, recorded_base \\ nil) do
    with {:ok, base} <- base_of(checkout, recorded_base),
         true <- plain_name?(base) || {:error, :unsafe_base},
         {:ok, base_ref} <- base_ref(checkout, base),
         {:ok, count} <-
           git(checkout, [
             "rev-list",
             "--count",
             "--no-merges",
             "#{base_ref}..refs/heads/#{branch}"
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
  @spec ancestor?(Path.t(), String.t(), base()) :: {:ok, boolean()} | {:error, term()}
  def ancestor?(checkout, head, base) do
    with {:ok, base_ref} <- resolve(checkout, base) do
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

  defp resolve(_checkout, {where, ref}) when where in [:local, :fetched], do: {:ok, ref}
  defp resolve(checkout, base), do: base_ref(checkout, base)

  @doc """
  Every place a landing in the base is read: the base as `on_branch/4` reads
  it, then the copy of it last fetched from its remote, when that holds
  commits the base here lacks. The fetched copy is what sees a merge request
  merged on the forge before anyone pulls.

  Each comes tagged, and `ancestor?/3`, `in_base?/3` and `reached_by_merge?/3`
  take it in place of a branch name.
  """
  @spec landing_refs(Path.t(), branch()) ::
          {:ok, [{:local | :fetched, String.t()}]} | {:error, term()}
  def landing_refs(checkout, base) do
    with {:ok, local} <- base_ref(checkout, base) do
      {:ok, [{:local, local} | fetched(checkout, base, local)]}
    end
  end

  defp fetched(checkout, base, local) do
    with {:ok, %{ref: ref}} when ref != local <- upstream(checkout, base),
         {:ok, false} <- ancestor?(checkout, ref, {:local, local}) do
      [{:fetched, ref}]
    else
      _ -> []
    end
  end

  # The remote branch the base tracks, else `origin`'s branch of the same name.
  # A tracked one that is not a plain name on a remote is unknown, never
  # `origin`'s. `for-each-ref` also lists the branches named under the base,
  # so only the base's own line is read.
  defp upstream(checkout, base) do
    own = "refs/heads/#{base}"
    format = "%(refname)%09%(upstream:remotename)%09%(upstream:remoteref)%09%(upstream)"

    with {:ok, out} <- git(checkout, ["for-each-ref", "--format=" <> format, own]) do
      out
      |> String.split("\n", trim: true)
      |> Enum.map(&String.split(&1, "\t"))
      |> Enum.find(&match?([^own | _], &1))
      |> case do
        nil ->
          origin(checkout, base)

        [^own] ->
          origin(checkout, base)

        [^own, "", "", ""] ->
          origin(checkout, base)

        [^own, remote, "refs/heads/" <> name, "refs/remotes/" <> _ = ref] ->
          tracked(remote, name, ref)

        _other ->
          {:error, :unusable_upstream}
      end
    end
  end

  defp tracked(remote, name, ref) do
    if plain_name?(remote) and plain_name?(name),
      do: {:ok, %{remote: remote, source: "refs/heads/" <> name, ref: ref}},
      else: {:error, :unusable_upstream}
  end

  defp origin(checkout, base) do
    case git(checkout, ["remote", "get-url", "origin"]) do
      {:ok, _url} ->
        {:ok,
         %{remote: "origin", source: "refs/heads/#{base}", ref: "refs/remotes/origin/#{base}"}}

      {:error, _} ->
        {:error, :no_remote}
    end
  end

  @doc """
  Fetch the base, and only the base, into its remote-tracking branch, the one
  `landing_refs/2` reads. Nothing else in the checkout moves: no local branch,
  no tag, no submodule, no `FETCH_HEAD`.

  It never stops to ask: a remote that wants a password or a passphrase
  fails, and no password program runs. An ssh command the person set is
  theirs and stays, and may ask on the terminal an owl run by hand holds,
  until `timeout`. A transfer that stalls gives up by itself; one still
  running at `timeout` is killed, with the programs it started, and is
  `{:error, :timeout}`.
  """
  @spec fetch_base(Path.t(), branch(), timeout()) :: :ok | {:error, term()}
  def fetch_base(checkout, base, timeout \\ 60_000) do
    with true <- plain_name?(base) || {:error, :unsafe_base},
         {:ok, %{remote: remote, source: source, ref: ref}} <- upstream(checkout, base) do
      args =
        ~w(-c http.lowSpeedLimit=1000 -c http.lowSpeedTime=30) ++
          ~w(fetch --quiet --no-tags --no-recurse-submodules --no-write-fetch-head --no-auto-maintenance) ++
          [remote, "+#{source}:#{ref}"]

      unattended(checkout, args, timeout)
    end
  end

  @doc "Fetch `branch` alone into its remote-tracking branch, as `fetch_base/3` fetches the base."
  @spec fetch_branch(Path.t(), branch(), timeout()) :: :ok | {:error, term()}
  def fetch_branch(checkout, branch, timeout \\ 60_000), do: fetch_base(checkout, branch, timeout)

  @doc "The commit `origin`'s copy of `branch` points at, as last fetched or pushed."
  @spec remote_head(Path.t(), branch()) :: {:ok, String.t()} | {:error, term()}
  def remote_head(checkout, branch) do
    with true <- plain_name?(branch) || {:error, :unsafe_branch} do
      case run(checkout, ["rev-parse", "--verify", "--quiet", "refs/remotes/origin/" <> branch]) do
        {out, 0} -> {:ok, String.trim(out)}
        _ -> {:error, :no_such_branch}
      end
    end
  end

  @doc """
  Check `branch` out in a new worktree at `path`: the branch as it is here,
  moved up to `origin`'s copy when that is only ahead of it, or else a new one
  from `origin`'s copy, tracking it. A worktree deleted by hand is first
  forgotten, so git does not hold its path or its branch; a branch checked
  out anywhere else is refused before anything moves.
  """
  @spec add_worktree(Path.t(), Path.t(), branch()) :: :ok | {:error, term()}
  def add_worktree(checkout, path, branch) do
    with true <- plain_name?(branch) || {:error, :unsafe_branch},
         :ok <- prune_worktrees(checkout),
         :ok <- if(checked_out?(checkout, branch), do: {:error, :checked_out}, else: :ok) do
      args =
        case branch_head(checkout, branch) do
          {:ok, here} ->
            catch_up(checkout, branch, here)
            ["worktree", "add", path, branch]

          {:error, _} ->
            ["worktree", "add", "--track", "-b", branch, path, "origin/" <> branch]
        end

      with {:ok, _} <- git(checkout, args), do: :ok
    end
  end

  # The main checkout counts: it is the first worktree git lists.
  defp checked_out?(checkout, branch) do
    case run(checkout, ["worktree", "list", "--porcelain"]) do
      {out, 0} -> out |> String.split("\n") |> Enum.member?("branch refs/heads/" <> branch)
      _ -> true
    end
  end

  # Commits here that `origin` lacks keep the branch where it is.
  defp catch_up(checkout, branch, here) do
    with {:ok, there} when there != here <- remote_head(checkout, branch),
         {_, 0} <- run(checkout, ["merge-base", "--is-ancestor", here, there]) do
      git(checkout, ["update-ref", "refs/heads/" <> branch, there, here])
    end
  end

  # A port rather than `System.cmd`, for its OS pid.
  defp unattended(checkout, args, timeout) do
    case System.find_executable("git") do
      git when is_binary(git) and is_binary(checkout) ->
        if File.dir?(checkout),
          do: unattended(git, checkout, args, timeout),
          else: {:error, :no_checkout}

      _ ->
        {:error, :no_git}
    end
  end

  defp unattended(git, checkout, args, timeout) do
    port =
      Port.open({:spawn_executable, git}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: args,
        cd: checkout,
        env: unattended_env(checkout)
      ])

    case await(port, System.monotonic_time(:millisecond) + timeout, "") do
      {:exit, 0, _out} ->
        :ok

      {:exit, code, out} ->
        {:error, {code, String.trim(out)}}

      :timeout ->
        with {:os_pid, os_pid} <- Port.info(port, :os_pid), do: kill(os_pid)
        await(port, System.monotonic_time(:millisecond) + 1_000, "")
        {:error, :timeout}
    end
  end

  # Git is stopped first, so it starts nothing more, and its own children —
  # ssh, a remote helper — go before it: once it is gone they would belong
  # to nobody this could name.
  defp kill(os_pid) do
    pid = Integer.to_string(os_pid)
    signal("kill", ["-STOP", pid])
    signal("pkill", ["-9", "-P", pid])
    signal("kill", ["-9", pid])
  end

  defp signal(program, args) do
    with path when is_binary(path) <- System.find_executable(program),
         do: System.cmd(path, args, stderr_to_stdout: true)
  end

  defp await(port, deadline, out) do
    receive do
      {^port, {:data, data}} -> await(port, deadline, out <> data)
      {^port, {:exit_status, code}} -> {:exit, code, out}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) -> :timeout
    end
  end

  # Git asks a password program before the terminal, and a port drops a
  # variable set to nothing, so the program named is one that always fails.
  defp unattended_env(checkout) do
    prompts = [
      {~c"GIT_TERMINAL_PROMPT", ~c"0"},
      {~c"GIT_ASKPASS", String.to_charlist(System.find_executable("false") || "/usr/bin/false")},
      {~c"GCM_INTERACTIVE", ~c"never"},
      {~c"SSH_ASKPASS_REQUIRE", ~c"never"}
    ]

    if own_ssh?(checkout),
      do: prompts,
      else: [{~c"GIT_SSH_COMMAND", String.to_charlist(@batch_ssh)} | prompts]
  end

  defp own_ssh?(checkout) do
    System.get_env("GIT_SSH_COMMAND") != nil or System.get_env("GIT_SSH") != nil or
      match?({:ok, _}, git(checkout, ["config", "--get", "core.sshCommand"]))
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
  @spec reached_by_merge?(Path.t(), String.t(), base()) :: {:ok, boolean()} | {:error, term()}
  def reached_by_merge?(checkout, head, base) do
    with {:ok, base_ref} <- resolve(checkout, base),
         {:ok, steps} <-
           git(checkout, ["rev-list", "--first-parent", "--count", "#{head}..#{base_ref}"]),
         {:ok, reached} <- git(checkout, ["rev-parse", "#{base_ref}~#{steps}"]) do
      {:ok, reached != head}
    end
  end

  @doc """
  Is this commit's work already in the base, under whatever commits carry it
  there now?

  Land here copies a branch's commits onto the base with new ids, a forge's
  squash folds them into one, and neither leaves the branch an ancestor of the
  base. A trial merge answers instead: merging the commit into the base would
  change nothing, so the base's tree is what the merge writes. Nothing is
  written to any ref or the index.

  Only for a commit with work of its own beyond the base: a branch that never
  moved merges to nothing too, and that is no landing (ADR-0064). A conflict
  is `false` — a copy whose conflict was resolved by hand usually reads that
  way, which leaves its worktree standing. A git too old for `merge-tree
  --write-tree` (before 2.38) is an error, never a `false` or a `true`.
  """
  @spec in_base?(Path.t(), String.t(), base()) :: {:ok, boolean()} | {:error, term()}
  def in_base?(checkout, head, base) do
    with {:ok, base_ref} <- resolve(checkout, base),
         {:ok, true} <- merges_to_base?(checkout, head, base_ref) do
      changes_anything?(checkout, head, base_ref)
    end
  end

  defp merges_to_base?(checkout, head, base_ref) do
    with {:ok, base_tree} <- git(checkout, ["rev-parse", "#{base_ref}^{tree}"]) do
      case run(checkout, ["merge-tree", "--write-tree", base_ref, head]) do
        {out, 0} -> {:ok, out |> String.split("\n") |> hd() == base_tree}
        {_conflicted, 1} -> {:ok, false}
        {out, code} -> {:error, {code, String.trim(out)}}
      end
    end
  end

  # Measured from where the branch last met the base, so a merge from the base
  # is not work of its own, and commits that cancel out are none either.
  defp changes_anything?(checkout, head, base_ref) do
    with {:ok, fork} <- git(checkout, ["merge-base", base_ref, head]) do
      case run(checkout, ["diff-tree", "--quiet", fork, head]) do
        {_, 0} -> {:ok, false}
        {_, 1} -> {:ok, true}
        {out, code} -> {:error, {code, String.trim(out)}}
      end
    end
  end

  @doc """
  Has this branch ever carried a commit of its own?

  A branch still on the commit it was cut at has nothing to land, and its tip
  is an ancestor of the base all the same (ADR-0061). The branch's own reflog
  names where it was cut: its oldest entry. A reflog that is empty or gone is
  `{:error, :no_reflog}`, never a guess either way.
  """
  @spec own_work?(Path.t(), branch(), String.t()) :: {:ok, boolean()} | {:error, term()}
  def own_work?(checkout, branch, head) do
    case run(checkout, ["reflog", "show", "--format=%H", "refs/heads/" <> branch]) do
      {out, 0} ->
        case out |> String.split("\n", trim: true) |> List.last() do
          nil -> {:error, :no_reflog}
          cut -> {:ok, String.trim(cut) != head}
        end

      {out, code} ->
        {:error, {code, String.trim(out)}}
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
  How many commits on a branch no remote has yet: what a push to its merge
  request would carry. The base's own commits are the base's to push, so a
  commit the base holds is never counted, pushed or not.
  """
  @spec not_pushed(Path.t(), branch(), branch() | nil) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def not_pushed(checkout, branch, recorded_base \\ nil) do
    with {:ok, base} <- base_of(checkout, recorded_base),
         {:ok, base_ref} <- base_ref(checkout, base),
         args = ["rev-list", "--count", "refs/heads/#{branch}", "--not", "--remotes", base_ref],
         {:ok, count} <- git(checkout, args ++ ["--"]),
         {n, ""} <- Integer.parse(count) do
      {:ok, n}
    else
      {:error, _} = error -> error
      _unparsed -> {:error, :unreadable}
    end
  end

  @doc """
  What a finished branch holds: its own commits beyond the base, counted as
  Land here lists them — merges from the base skipped — and the paths its
  worktree has not committed, untracked ones included, as git lists them. A
  commit in the fetched copy of the base is not beyond it: a merge request
  merged on the forge leaves nothing to land.

  Anything git will not say plainly is an error, never an empty branch: a
  worktree that is not there (`:no_worktree`), one moved off `branch`
  (`:off_branch`), a base whose name is not plain (`:unsafe_base`), or output
  with a warning in it. The finish options take nothing for "nothing to land".
  """
  @spec on_branch(Path.t(), Path.t(), branch(), branch() | nil) ::
          {:ok,
           %{
             base: branch(),
             ahead: non_neg_integer(),
             uncommitted: [String.t()]
           }}
          | {:error, term()}
  def on_branch(checkout, worktree, branch, recorded_base \\ nil) do
    with true <- File.dir?(worktree) || {:error, :no_worktree},
         {:ok, ^branch} <- head_branch(worktree) |> off_branch(),
         {:ok, base} <- base_of(checkout, recorded_base),
         true <- plain_name?(base) || {:error, :unsafe_base},
         {:ok, [{:local, _base_ref} | _] = places} <- landing_refs(checkout, base),
         beyond = ["refs/heads/#{branch}", "--not" | Enum.map(places, &elem(&1, 1))],
         {:ok, count} <- git(checkout, ["rev-list", "--count", "--no-merges" | beyond]),
         {ahead, ""} <- Integer.parse(count),
         {:ok, uncommitted} <- uncommitted(worktree) do
      {:ok, %{base: base, ahead: ahead, uncommitted: uncommitted}}
    else
      {:ok, _other_branch} -> {:error, :off_branch}
      {:error, _} = error -> error
      _unparsed_count -> {:error, :unreadable}
    end
  end

  @doc """
  What a finished branch would land, as `git diff <base>...<branch>` prints it:
  from where it left the base to its tip, the base read as `on_branch/4` reads
  it. No external diff program or text conversion runs, whatever git's config
  names, and no diff is started inside a submodule, where those flags would not
  reach. Nothing a partial clone left out is fetched, so no transport git's
  config names runs either. Git's warnings stay out of the diff.
  """
  @spec branch_diff(Path.t(), branch(), branch() | nil) ::
          {:ok, String.t()} | {:error, term()}
  def branch_diff(checkout, branch, recorded_base \\ nil) do
    args = ["diff", "--no-color", "--no-ext-diff", "--no-textconv", "--submodule=short"]

    with {:ok, base} <- base_of(checkout, recorded_base),
         true <- plain_name?(base) || {:error, :unsafe_base},
         {:ok, base_ref} <- base_ref(checkout, base),
         range = "#{base_ref}...refs/heads/#{branch}",
         {diff, 0} <-
           System.cmd("git", args ++ [range, "--"],
             cd: checkout,
             stderr_to_stdout: false,
             env: [{"GIT_NO_LAZY_FETCH", "1"}]
           ) do
      {:ok, diff}
    else
      {out, code} when is_integer(code) -> {:error, {code, String.trim(out)}}
      {:error, _} = error -> error
    end
  end

  @doc """
  What a branch changed since commit `from`, tree to tree, so a commit squashed
  since still shows as its change. The same flags as `branch_diff/3`; `from`
  must be a full commit id.
  """
  @spec round_diff(Path.t(), branch(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def round_diff(checkout, branch, from) do
    args = ["diff", "--no-color", "--no-ext-diff", "--no-textconv", "--submodule=short"]

    with true <- Regex.match?(~r/\A([0-9a-f]{40}|[0-9a-f]{64})\z/, from) || {:error, :unsafe_ref},
         true <- plain_name?(branch) || {:error, :unsafe_branch},
         {diff, 0} <-
           System.cmd("git", args ++ [from, "refs/heads/#{branch}", "--"],
             cd: checkout,
             stderr_to_stdout: false,
             env: [{"GIT_NO_LAZY_FETCH", "1"}]
           ) do
      {:ok, diff}
    else
      {out, code} when is_integer(code) -> {:error, {code, String.trim(out)}}
      {:error, _} = error -> error
    end
  end

  defp off_branch({:error, :detached}), do: {:error, :off_branch}
  defp off_branch(head), do: head

  # The base is printed for the main session, which builds git commands from
  # it; a name with anything else in it is a name a mouse chose.
  defp plain_name?(name), do: Regex.match?(~r/\A[A-Za-z0-9._\/][A-Za-z0-9._\/-]*\z/, name)

  @doc """
  The commits a branch carries beyond its base, oldest first and merges from
  the base left out: what landing it copies.
  """
  @spec own_commits(Path.t(), branch(), branch() | nil) ::
          {:ok, %{base: branch(), commits: [String.t()]}} | {:error, term()}
  def own_commits(checkout, branch, recorded_base \\ nil) do
    with {:ok, base} <- base_of(checkout, recorded_base),
         {:ok, base_ref} <- base_ref(checkout, base),
         range = "#{base_ref}..refs/heads/#{branch}",
         {:ok, out} <-
           git(checkout, ["log", "--no-merges", "--reverse", "--format=%H", range, "--"]) do
      {:ok, %{base: base, commits: String.split(out, "\n", trim: true)}}
    end
  end

  @doc """
  The commits on a branch that neither a remote nor the base holds, newest
  first, each as its short id and subject: what deleting the branch loses.
  """
  @spec unpushed_commits(Path.t(), branch(), branch() | nil) ::
          {:ok, [String.t()]} | {:error, term()}
  def unpushed_commits(checkout, branch, recorded_base \\ nil) do
    with {:ok, base} <- base_of(checkout, recorded_base),
         {:ok, base_ref} <- base_ref(checkout, base),
         args = ["log", "--format=%h %s", "refs/heads/#{branch}", "--not", "--remotes", base_ref],
         {:ok, out} <- git(checkout, args ++ ["--"]) do
      {:ok, String.split(out, "\n", trim: true)}
    end
  end

  @doc """
  The paths a worktree has not committed, untracked ones included, as git
  lists them.

  `-z` keeps each path whole and unquoted; a rename or copy carries its
  source as the next field, which is not a second uncommitted path. Every
  untracked file is listed whatever the person's `status.showUntrackedFiles`
  says, and no optional lock is taken on an index a session may be using.
  """
  @spec uncommitted(Path.t()) :: {:ok, [String.t()]} | {:error, term()}
  def uncommitted(worktree) do
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

  @spec tracked?(Path.t(), String.t()) :: boolean()
  def tracked?(worktree, path) do
    match?(
      {_, 0},
      run(worktree, ["--literal-pathspecs", "ls-files", "--error-unmatch", "--", path])
    )
  end

  @doc "Remove a worktree, never forcing. Git refuses a dirty one, and that refusal stands."
  @spec remove_worktree(Path.t(), Path.t()) :: :ok | {:error, term()}
  def remove_worktree(checkout, worktree) do
    with {:ok, _} <- git(checkout, ["worktree", "remove", worktree]), do: :ok
  end

  @doc """
  Delete a branch with `-d`. Git refuses an unmerged one, and so do we.

  `{:in_base, head}` is the one exception. `-d` judges a branch against its
  upstream, or with none against the main checkout's HEAD, never against
  where its landing was found: it refuses a branch landed as copies, and
  answers one only the fetched copy of the base holds by its own measure. It
  is deleted only while it still points at `head`, the commit that was
  checked, so a commit made since keeps it. Its branch settings stay where
  they are.
  """
  @spec delete_branch(Path.t(), branch(), :merged | {:in_base, String.t()}) ::
          :ok | {:error, term()}
  def delete_branch(checkout, branch, landing \\ :merged)

  def delete_branch(checkout, branch, :merged) do
    with {:ok, _} <- git(checkout, ["branch", "-d", branch]), do: :ok
  end

  def delete_branch(checkout, branch, {:in_base, head}) do
    with {:ok, _} <- git(checkout, ["update-ref", "-d", "refs/heads/" <> branch, head]), do: :ok
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

  # A partial clone fetches a missing object the moment a command needs one;
  # here that is an error, so a question never reaches the network.
  defp run(dir, args) do
    if File.dir?(dir) do
      System.cmd("git", args, cd: dir, stderr_to_stdout: true, env: [{"GIT_NO_LAZY_FETCH", "1"}])
    else
      {"no such directory: #{dir}", 128}
    end
  end
end
