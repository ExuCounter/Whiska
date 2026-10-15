defmodule Whiska.Cleanup do
  @moduledoc """
  Taking a landed worktree down, pane and all (ADR-0061).

  One pass over this house's mice, run from the backstop. A worktree goes only
  when all four preconditions hold — the branch has landed in the base, merged
  or as copies of its commits, in the base here or in its copy last fetched
  from the remote, or its merge request read merged on the forge on the
  worktree's own head, into any branch, the worktree is clean, nothing on it is
  unpushed, and the mouse is quiet — and
  the pane goes with it, through the one `worktree.remove` call herdr offers,
  which closes the workspace and removes the worktree together the way
  `whiska drop` does. A sniff mouse's branch has nothing to merge: it lands by
  its builds instead, and goes clean and never moved (ADR-0061).

  **Unknown is never permission.** Anything that cannot be established — a
  detached head, a base branch nobody can name, a herdr that will not answer, a
  live pane whose workspace herdr does not name — leaves the worktree exactly
  where it is. Nothing is forced, and nothing is retried harder next time.

  The pass has a second job, which refuses nothing and removes nothing
  (ADR-0064): noting that a branch has landed, for every mouse rather than only
  for the ones that may go. That stamp is what later settles a question its
  mouse left waiting rather than orphaning it.

  The mouse record is stamped, never deleted: ADR-0007's reasoning about the
  record survives its worktree half being superseded.
  """

  alias Whiska.Doorstep
  alias Whiska.Git
  alias Whiska.Layout
  alias Whiska.Review
  alias Whiska.Schema.MergeRequestRead
  alias Whiska.Schema.Mouse
  alias Whiska.Schema.Question
  alias Whiska.Storage

  @ready ~w(idle done)
  @waiting ~w(open sent)

  @typedoc "What one sweep did to one mouse."
  @type outcome ::
          :removed
          | {:removed, {:branch_kept | :unrecorded, term()}}
          | {:left, atom() | {atom(), term()}}

  @doc """
  One pass over every mouse of this house whose worktree is still standing.

  Returns what became of each, in record order. A house with nothing standing
  asks herdr nothing.
  """
  @spec sweep(%{main_checkout: Path.t(), herdr: module(), socket: Path.t() | nil}) ::
          [{String.t(), outcome()}]
  def sweep(%{main_checkout: checkout} = house) do
    standing = Storage.current_mice() |> Enum.reject(& &1.removed_at)

    questions =
      Storage.all(Question) |> Enum.reject(&Question.owls?/1) |> Enum.group_by(& &1.mouse_id)

    local = %{
      checkout: checkout,
      questions: questions,
      builds: builds(questions),
      doorstep: doorstep(checkout),
      bases: bases(checkout, standing),
      reads: Storage.merge_request_reads()
    }

    standing
    |> Enum.map(&note_landing(&1, local))
    |> Enum.map(fn {mouse, asked} ->
      {mouse, local_verdict(mouse, Map.put(local, :merged, asked))}
    end)
    |> finish(house, local)
  end

  # The sweep's other job, and the one it does for every standing and every
  # vanished worktree alike (ADR-0064): noting that a branch has landed. A
  # mouse holding a question is never torn down, but its branch landing is what
  # settles that question when there is finally nobody left to answer to.
  # Returns the mouse with git's answer to "how did the base reach this", which
  # the teardown asks for again a line later: carrying it across is what keeps
  # one sweep to one such check per standing worktree. A mouse already stamped
  # is asked again only while a merge request recorded after its landing waits.
  defp note_landing(%Mouse{landed_at: %DateTime{}} = mouse, local) do
    if Mouse.merge_request_waiting?(mouse), do: ask_landing(mouse, local), else: {mouse, nil}
  end

  defp note_landing(mouse, local), do: ask_landing(mouse, local)

  defp ask_landing(mouse, local) do
    with {:ok, {base, places}} <- base(mouse, local),
         {:ok, head} <- head_of(mouse, local, base),
         {:ok, how} = asked <- reached(local.checkout, head, places) do
      {stamp_if_landed(how, mouse, local, head), shareable(mouse, asked)}
    else
      _ -> {mouse, nil}
    end
  end

  # Each recorded base is named, and the places it is read found, once a
  # sweep: every mouse cut from the same branch shares the answer.
  defp bases(checkout, mice) do
    mice
    |> Enum.map(& &1.base)
    |> Enum.uniq()
    |> Map.new(&{&1, base_and_places(checkout, &1)})
  end

  defp base_and_places(checkout, recorded) do
    with {:ok, base} <- Git.base_of(checkout, recorded),
         {:ok, places} <- Git.landing_refs(checkout, base),
         do: {:ok, {base, places}}
  end

  defp base(%Mouse{base: recorded}, local) do
    Map.get_lazy(local[:bases] || %{}, recorded, fn ->
      base_and_places(local.checkout, recorded)
    end)
  end

  # How the base holds this commit, and where: as an ancestor, as the same
  # work under other commits — Land here's copies, a squash — or not at all.
  # The base here first, then its copy last fetched, where a merge request
  # merged on the forge shows before anyone pulls.
  defp reached(_checkout, _head, []), do: {:ok, false}

  defp reached(checkout, head, [where | rest]) do
    case Git.ancestor?(checkout, head, where) do
      {:ok, true} ->
        {:ok, {:ancestor, where}}

      {:ok, false} ->
        case Git.in_base?(checkout, head, where) do
          {:ok, true} -> {:ok, {:in_base, where}}
          {:ok, false} -> reached(checkout, head, rest)
          error -> error
        end

      error ->
        error
    end
  end

  # An ancestor of the base is not yet a landing: a branch cut an hour ago and
  # never moved is one too. Only work the base reached through a merge, or
  # holds as copies, settles anything (ADR-0064).
  defp stamp_if_landed({:in_base, _where}, mouse, _local, _head), do: stamp_landing(mouse)

  defp stamp_if_landed({:ancestor, where}, mouse, local, head) do
    case Git.reached_by_merge?(local.checkout, head, where) do
      {:ok, true} -> stamp_landing(mouse)
      _ -> mouse
    end
  end

  defp stamp_if_landed(false, mouse, _local, _head), do: mouse

  defp stamp_landing(mouse) do
    case Storage.mark_landed(mouse.mouse_id) do
      {:ok, stamped} -> stamped
      {:error, _} -> mouse
    end
  end

  # While the worktree stands its own head is the authority, the same one the
  # teardown reads. Once it is gone the branch ref is all that is left, and a
  # branch deleted with it leaves the landing unknown — which is not a landing.
  # The base branch is never read as one: it is merged into itself.
  defp head_of(%Mouse{path: path, branch: branch}, local, base) do
    cond do
      is_binary(path) and File.dir?(path) -> Git.head(path)
      branch == base -> {:error, :base_branch}
      is_binary(branch) -> Git.branch_head(local.checkout, branch)
      true -> {:error, :nothing_to_ask}
    end
  end

  # Only a standing worktree's own head answers the teardown's first
  # precondition, so only that answer is ever carried across to it (ADR-0061).
  defp shareable(%Mouse{path: path}, asked) do
    if is_binary(path) and File.dir?(path), do: asked, else: nil
  end

  # herdr is asked only once something has passed every check this machine can
  # answer by itself, so a house with nothing landed never opens a socket.
  defp finish(judged, house, local) do
    if Enum.any?(judged, &match?({_, {:ok, _}}, &1)) do
      case context(house, local) do
        {:ok, context} ->
          Enum.map(judged, fn {mouse, v} -> {mouse.mouse_id, act(mouse, v, context)} end)

        {:error, reason} ->
          Enum.map(judged, fn
            {mouse, {:leave, refused}} -> {mouse.mouse_id, {:left, refused}}
            {mouse, {:ok, _}} -> {mouse.mouse_id, {:left, reason}}
          end)
      end
    else
      Enum.map(judged, fn {mouse, {:leave, reason}} -> {mouse.mouse_id, {:left, reason}} end)
    end
  end

  defp act(_mouse, {:leave, reason}, _context), do: {:left, reason}

  defp act(mouse, {:ok, landed}, context) do
    case teardown(mouse, landed, context) do
      {:ok, plan} -> take_down(mouse, plan, context)
      {:leave, reason} -> {:left, reason}
    end
  end

  # What herdr says about the worktree, which is the last word on whether it may
  # go. A pane sitting in the worktree and an open workspace on it have to agree:
  # a workspace nothing accounts for, or a pane herdr opened no workspace for, is
  # unknown — and the record's own `pane` column is never the authority, since a
  # match that has gone stale would read as "no pane" and close a live session.
  defp teardown(%Mouse{path: path} = mouse, {branch, landing}, context) do
    statuses = statuses_in(mouse, context)
    workspace_id = Map.get(context.workspaces, Layout.canonical(path))
    plan = %{path: path, branch: branch, landing: landing, workspace_id: workspace_id}

    cond do
      Enum.any?(statuses, &(&1 not in @ready)) -> {:leave, :working}
      statuses == [] and is_nil(workspace_id) -> {:ok, plan}
      statuses != [] and is_binary(workspace_id) -> {:ok, plan}
      true -> {:leave, :unknown_workspace}
    end
  end

  defp statuses_in(%Mouse{path: path, pane: pane}, context) do
    context.panes
    |> Enum.filter(&(in_worktree?(&1, path) or &1.pane_id == pane))
    |> Enum.map(& &1.agent_status)
  end

  defp in_worktree?(%{cwd: cwd}, path) when is_binary(cwd), do: Layout.inside?(cwd, path)
  defp in_worktree?(_pane, _path), do: false

  defp context(%{herdr: herdr, socket: socket}, local) do
    with {:ok, panes} <- herdr.list_panes(socket),
         {:ok, worktrees} <- herdr.worktrees(socket, local.checkout) do
      {:ok,
       Map.merge(local, %{
         herdr: herdr,
         socket: socket,
         panes: panes,
         workspaces: Map.new(worktrees, &{Layout.canonical(&1.path), &1.workspace_id})
       })}
    else
      {:error, _} -> {:error, :no_herdr}
    end
  end

  # Every mouse `whiska spawn --from` built, under the mouse that asked the
  # question it was built from, each with whether its worktree still stands:
  # a record a newer one took the folder from is never removed, and is gone.
  defp builds(questions) do
    asker = for {mouse_id, asked} <- questions, q <- asked, into: %{}, do: {q.id, mouse_id}
    mice = Storage.all(Mouse)
    current = mice |> Storage.current() |> MapSet.new(& &1.mouse_id)

    for %Mouse{built_from: from} = build <- mice, from, reduce: %{} do
      acc ->
        standing? = is_nil(build.removed_at) and MapSet.member?(current, build.mouse_id)
        Map.update(acc, asker[from], [{build, standing?}], &[{build, standing?} | &1])
    end
  end

  # A held stop is a turn the owl has not yet collected, and its mouse's
  # worktree is no more ready to go than for one on the doorstep (ADR-0052).
  defp doorstep(checkout) do
    (Doorstep.waiting(checkout) ++ Doorstep.held(checkout))
    |> MapSet.new(fn {_file, entry} -> entry.mouse_id end)
  end

  @doc """
  What this machine alone can say about one mouse's worktree, and why.

  The checks run cheapest first and the first one to refuse is the answer, so a
  reason always names the nearest thing standing in the way rather than the
  worst one. Whether its pane is busy is not here: that is herdr's to say.
  """
  @spec local_verdict(Mouse.t(), map()) ::
          {:ok, {String.t(), :merged | {:in_base | :built, String.t()}}} | {:leave, term()}
  def local_verdict(%Mouse{path: path} = mouse, local) do
    with :ok <- standing(path),
         :ok <- not_held(mouse),
         :ok <- quiet(mouse, local),
         do: landed(mouse, local)
  end

  defp standing(path) do
    if is_binary(path) and File.dir?(path), do: :ok, else: {:leave, :gone}
  end

  # A fifth precondition (ADR-0079): the
  # person said this one stops where it is, and that includes its worktree.
  defp not_held(%Mouse{held_at: %DateTime{}}), do: {:leave, :held}
  defp not_held(_mouse), do: :ok

  defp quiet(%Mouse{mouse_id: id}, local) do
    questions = Map.get(local.questions, id, [])

    cond do
      Enum.any?(questions, &(&1.status in @waiting)) -> {:leave, :waiting}
      MapSet.member?(local.doorstep, id) -> {:leave, :uncollected}
      not finished?(questions) -> {:leave, :not_finished}
      true -> :ok
    end
  end

  defp finished?([]), do: false
  # When it was asked, not when the owl happened to collect it.
  defp finished?(questions),
    do: Enum.max_by(questions, &{DateTime.to_unix(&1.asked_at), &1.id}).kind == "done"

  # A sniff mouse's branch has nothing to merge, so it lands by its builds
  # instead (ADR-0074): every one built from its questions gone, one of them
  # landed. Only while the branch never moved; one that did is asked as any
  # other branch is.
  defp landed(%Mouse{mode: "sniff", shaped_as: "sniff", mouse_id: id} = mouse, context)
       when is_map_key(context.builds, id) do
    with {:ok, branch} <- leave_on_error(Git.head_branch(mouse.path)),
         {:ok, head} <- leave_on_error(Git.head(mouse.path)) do
      case Git.own_work?(context.checkout, branch, head) do
        {:ok, false} ->
          with :ok <- built_landed(context.builds[id]),
               {:ok, true} <- clean(mouse.path),
               do: {:ok, {branch, {:built, head}}}

        {:ok, true} ->
          landed_as_branch(mouse, context)

        other ->
          leave_on_error(other)
      end
    end
  end

  defp landed(mouse, context), do: landed_as_branch(mouse, context)

  @spec built_landed([{Mouse.t(), boolean()}]) ::
          :ok | {:leave, :build_standing | :no_build_landed}
  defp built_landed(builds) do
    cond do
      Enum.any?(builds, &elem(&1, 1)) -> {:leave, :build_standing}
      Enum.any?(builds, fn {build, _} -> build.landed_at end) -> :ok
      true -> {:leave, :no_build_landed}
    end
  end

  defp landed_as_branch(%Mouse{path: path} = mouse, %{checkout: checkout} = context) do
    with {:ok, places} <- places(mouse, context),
         {:ok, branch} <- leave_on_error(Git.head_branch(path)),
         {:ok, how} <- merged(mouse, places, context),
         {:ok, landing} <- confirmed(checkout, path, how),
         {:ok, true} <- own_work(checkout, path, branch),
         {:ok, true} <- clean(path),
         {:ok, false} <- unpushed(path, branch, landing) do
      {:ok, {branch, landing}}
    end
  end

  # A branch landed as copies, or held only by the fetched base, is deleted
  # only while it is still on the commit found there, so that commit is asked
  # about here, not one remembered from earlier in the sweep.
  defp confirmed(_checkout, _path, {:ancestor, {:local, _ref}}), do: {:ok, :merged}

  defp confirmed(_checkout, path, {:forge, head}) do
    case leave_on_error(Git.head(path)) do
      {:ok, ^head} -> {:ok, {:in_base, head}}
      {:ok, _moved} -> {:leave, :not_merged}
      leave -> leave
    end
  end

  defp confirmed(checkout, path, {how, where}) do
    with {:ok, head} <- leave_on_error(Git.head(path)) do
      case still(how, checkout, head, where) do
        {:ok, true} -> {:ok, {:in_base, head}}
        {:ok, false} -> {:leave, :not_merged}
        other -> leave_on_error(other)
      end
    end
  end

  defp still(:ancestor, checkout, head, where), do: Git.ancestor?(checkout, head, where)
  defp still(:in_base, checkout, head, where), do: Git.in_base?(checkout, head, where)

  # A base that cannot be read leaves the worktree, unless the forge merged
  # its head, whatever branch that went into.
  defp places(mouse, context) do
    case base(mouse, context) do
      {:ok, {_base, places}} -> {:ok, places}
      unreadable -> {:ok, {:unreadable, leave_on_error(unreadable)}}
    end
  end

  defp merged(mouse, {:unreadable, leave}, context) do
    with {:leave, _not_merged} <- merged_on_forge(mouse, context), do: leave
  end

  defp merged(%Mouse{path: path} = mouse, places, context) do
    asked =
      context[:merged] ||
        with({:ok, head} <- Git.head(path), do: reached(context.checkout, head, places))

    case asked do
      {:ok, false} -> merged_on_forge(mouse, context)
      other -> leave_on_error(other)
    end
  end

  # A merge the forge read, into whatever branch, is a landing when it merged
  # the worktree's own head: the work is on the forge, so nothing here is
  # unpushed, whether or not the forge kept the source branch. Only the read
  # of the link recorded now, while it waits (ADR-0061).
  defp merged_on_forge(%Mouse{mouse_id: id, merge_request_url: url} = mouse, context) do
    with %MergeRequestRead{url: ^url, state: "merged", head_sha: sha} when is_binary(sha) <-
           (context[:reads] || %{})[id],
         true <- Mouse.merge_request_waiting?(mouse),
         {:ok, ^sha} <- Git.head(mouse.path) do
      {:ok, {:forge, sha}}
    else
      _ -> {:leave, :not_merged}
    end
  end

  # An ancestor of the base is not yet a landing: a branch that never moved —
  # a sniff mouse's with no build landed, or a build mouse that committed
  # nothing — is one too, and its worktree is the person's to drop (ADR-0061).
  defp own_work(checkout, path, branch) do
    with {:ok, head} <- leave_on_error(Git.head(path)) do
      case Git.own_work?(checkout, branch, head) do
        {:ok, false} -> {:leave, :no_work_of_its_own}
        other -> leave_on_error(other)
      end
    end
  end

  defp clean(path) do
    case Git.clean?(path) do
      {:ok, false} -> {:leave, :dirty}
      other -> leave_on_error(other)
    end
  end

  # Work the base holds as copies is as safe as the base is: the branch's own
  # commits were never going to be pushed once Land here took them.
  defp unpushed(_path, _branch, {:in_base, _head}), do: {:ok, false}

  defp unpushed(path, branch, :merged) do
    case Git.unpushed?(path, branch) do
      {:ok, true} -> {:leave, :unpushed}
      other -> leave_on_error(other)
    end
  end

  defp leave_on_error({:error, reason}) when is_atom(reason), do: {:leave, reason}
  defp leave_on_error({:error, reason}), do: {:leave, {:unreadable, reason}}
  defp leave_on_error(ok), do: ok

  defp deleted_as({:built, head}), do: {:in_base, head}
  defp deleted_as(landing), do: landing

  defp take_down(mouse, plan, context) do
    with :ok <- remove(plan, context) do
      Git.prune_worktrees(context.checkout)
      recorded = Storage.mark_removed(mouse.mouse_id)
      deleted = Git.delete_branch(context.checkout, plan.branch, deleted_as(plan.landing))
      if deleted == :ok, do: Review.remove(context.checkout, plan.branch)

      case {recorded, deleted} do
        {{:ok, _}, :ok} -> :removed
        {{:error, reason}, _} -> {:removed, {:unrecorded, reason}}
        {_, {:error, reason}} -> {:removed, {:branch_kept, reason}}
      end
    else
      {:error, reason} -> {:left, {:not_removed, reason}}
    end
  end

  defp remove(%{workspace_id: nil, path: path}, context),
    do: Git.remove_worktree(context.checkout, path)

  defp remove(%{workspace_id: workspace_id}, context),
    do: context.herdr.remove_worktree(context.socket, workspace_id)
end
