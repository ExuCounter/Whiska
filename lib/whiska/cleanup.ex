defmodule Whiska.Cleanup do
  @moduledoc """
  Taking a landed worktree down, pane and all (ADR-0061).

  One pass over this house's mice, run from the backstop. A worktree goes only
  when all four preconditions hold — the branch is merged into the base, the
  worktree is clean, nothing on it is unpushed, and the mouse is quiet — and
  the pane goes with it, through the one `worktree.remove` call herdr offers,
  which closes the workspace and removes the worktree together the way the
  `drop-worktree` skill always has.

  **Unknown is never permission.** Anything that cannot be established — a
  detached head, a base branch nobody can name, a herdr that will not answer, a
  live pane whose workspace herdr does not name — leaves the worktree exactly
  where it is. Nothing is forced, and nothing is retried harder next time.

  The mouse record is stamped, never deleted: ADR-0007's reasoning about the
  record survives its worktree half being superseded.
  """

  alias Whiska.Doorstep
  alias Whiska.Git
  alias Whiska.Layout
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
    local = %{
      checkout: checkout,
      base: Git.base(checkout),
      questions: Enum.group_by(Storage.all(Question), & &1.mouse_id),
      doorstep: doorstep(checkout)
    }

    Storage.current_mice()
    |> Enum.reject(& &1.removed_at)
    |> Enum.map(&note_landing(&1, local))
    |> Enum.map(&{&1, local_verdict(&1, local)})
    |> finish(house, local)
  end

  # The sweep's other job, and the one it does for every standing and every
  # vanished worktree alike (ADR-0063): noting that a branch has landed. A
  # mouse holding a question is never torn down, but its branch landing is what
  # settles that question when there is finally nobody left to answer to.
  defp note_landing(%Mouse{landed_at: %DateTime{}} = mouse, _local), do: mouse

  defp note_landing(mouse, local) do
    with true <- landed?(mouse, local),
         {:ok, stamped} <- Storage.mark_landed(mouse.mouse_id) do
      stamped
    else
      _ -> mouse
    end
  end

  # While the worktree stands its own head is the authority, the same one the
  # teardown checks. Once it is gone the branch ref is all that is left, and a
  # branch deleted with it leaves the landing unknown — which is not a landing.
  defp landed?(mouse, local) do
    with {:ok, base} <- local.base,
         {:ok, true} <- landing(mouse, local.checkout, base) do
      true
    else
      _ -> false
    end
  end

  defp landing(%Mouse{path: path, branch: branch}, checkout, base) do
    cond do
      is_binary(path) and File.dir?(path) -> Git.merged?(checkout, path, base)
      is_binary(branch) -> Git.branch_merged?(checkout, branch, base)
      true -> {:error, :nothing_to_ask}
    end
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

  defp act(mouse, {:ok, branch}, context) do
    case teardown(mouse, branch, context) do
      {:ok, plan} -> take_down(mouse, plan, context)
      {:leave, reason} -> {:left, reason}
    end
  end

  # What herdr says about the worktree, which is the last word on whether it may
  # go. A pane sitting in the worktree and an open workspace on it have to agree:
  # a workspace nothing accounts for, or a pane herdr opened no workspace for, is
  # unknown — and the record's own `pane` column is never the authority, since a
  # match that has gone stale would read as "no pane" and close a live session.
  defp teardown(%Mouse{path: path} = mouse, branch, context) do
    statuses = statuses_in(mouse, context)
    workspace_id = Map.get(context.workspaces, Layout.canonical(path))
    plan = %{path: path, branch: branch, workspace_id: workspace_id}

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

  defp doorstep(checkout) do
    checkout
    |> Doorstep.waiting()
    |> MapSet.new(fn {_file, entry} -> entry.mouse_id end)
  end

  @doc """
  What this machine alone can say about one mouse's worktree, and why.

  The checks run cheapest first and the first one to refuse is the answer, so a
  reason always names the nearest thing standing in the way rather than the
  worst one. Whether its pane is busy is not here: that is herdr's to say.
  """
  @spec local_verdict(Mouse.t(), map()) :: {:ok, String.t()} | {:leave, term()}
  def local_verdict(%Mouse{path: path} = mouse, local) do
    with :ok <- standing(path),
         :ok <- quiet(mouse, local),
         do: landed(mouse, local)
  end

  defp standing(path) do
    if is_binary(path) and File.dir?(path), do: :ok, else: {:leave, :gone}
  end

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

  defp landed(%Mouse{path: path}, %{checkout: checkout} = context) do
    with {:ok, base} <- leave_on_error(context.base),
         {:ok, branch} <- leave_on_error(Git.head_branch(path)),
         {:ok, true} <- merged(checkout, path, base),
         {:ok, true} <- clean(path),
         {:ok, false} <- unpushed(path, branch) do
      {:ok, branch}
    end
  end

  defp merged(checkout, path, base) do
    case Git.merged?(checkout, path, base) do
      {:ok, false} -> {:leave, :not_merged}
      other -> leave_on_error(other)
    end
  end

  defp clean(path) do
    case Git.clean?(path) do
      {:ok, false} -> {:leave, :dirty}
      other -> leave_on_error(other)
    end
  end

  defp unpushed(path, branch) do
    case Git.unpushed?(path, branch) do
      {:ok, true} -> {:leave, :unpushed}
      other -> leave_on_error(other)
    end
  end

  defp leave_on_error({:error, reason}) when is_atom(reason), do: {:leave, reason}
  defp leave_on_error({:error, reason}), do: {:leave, {:unreadable, reason}}
  defp leave_on_error(ok), do: ok

  defp take_down(mouse, plan, context) do
    with :ok <- remove(plan, context) do
      Git.prune_worktrees(context.checkout)
      recorded = Storage.mark_removed(mouse.mouse_id)

      case {recorded, Git.delete_branch(context.checkout, plan.branch)} do
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
