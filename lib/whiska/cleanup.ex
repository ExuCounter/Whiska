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
  alias Whiska.Schema.Mouse
  alias Whiska.Schema.Question
  alias Whiska.Storage

  @ready ~w(idle done)
  @waiting ~w(open sent)

  @typedoc "What one sweep did to one mouse."
  @type outcome ::
          :removed | {:removed, {:branch_kept, term()}} | {:left, atom() | {atom(), term()}}

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
    |> Enum.map(&{&1, local_verdict(&1, local)})
    |> finish(house, local)
  end

  # herdr is asked only once something has passed every check this machine can
  # answer by itself, so a house with nothing landed never opens a socket.
  defp finish(judged, house, local) do
    if Enum.any?(judged, &match?({_, {:ok, _}}, &1)) do
      case context(house, local) do
        {:ok, context} ->
          Enum.map(judged, fn {mouse, v} -> {mouse.mouse_id, act(mouse, v, context)} end)

        {:error, reason} ->
          Enum.map(judged, &{elem(&1, 0).mouse_id, {:left, reason}})
      end
    else
      Enum.map(judged, fn {mouse, {:leave, reason}} -> {mouse.mouse_id, {:left, reason}} end)
    end
  end

  defp act(_mouse, {:leave, reason}, _context), do: {:left, reason}

  defp act(mouse, {:ok, branch}, context) do
    with :ok <- idle(mouse, context),
         {:ok, workspace_id} <- workspace(mouse, context) do
      take_down(mouse, %{path: mouse.path, branch: branch, workspace_id: workspace_id}, context)
    else
      {:leave, reason} -> {:left, reason}
    end
  end

  defp context(%{herdr: herdr, socket: socket}, local) do
    with {:ok, panes} <- herdr.list_panes(socket),
         {:ok, worktrees} <- herdr.worktrees(socket, local.checkout) do
      {:ok,
       Map.merge(local, %{
         herdr: herdr,
         socket: socket,
         panes: Map.new(panes, &{&1.pane_id, &1.agent_status}),
         workspaces: Map.new(worktrees, &{Path.expand(&1.path), &1.workspace_id})
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

  defp idle(%Mouse{pane: pane}, context) do
    if busy?(pane, context.panes), do: {:leave, :working}, else: :ok
  end

  defp finished?([]), do: false
  defp finished?(questions), do: Enum.max_by(questions, & &1.id).kind == "done"

  defp busy?(nil, _panes), do: false

  defp busy?(pane, panes) do
    case Map.fetch(panes, pane) do
      {:ok, status} -> status not in @ready
      :error -> false
    end
  end

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

  defp workspace(%Mouse{path: path, pane: pane}, context) do
    case {Map.get(context.workspaces, Path.expand(path)), live?(pane, context.panes)} do
      {nil, true} -> {:leave, :unknown_workspace}
      {workspace_id, _} -> {:ok, workspace_id}
    end
  end

  defp live?(nil, _panes), do: false
  defp live?(pane, panes), do: Map.has_key?(panes, pane)

  defp take_down(mouse, plan, context) do
    with :ok <- remove(plan, context) do
      Git.prune_worktrees(context.checkout)
      {:ok, _} = Storage.mark_removed(mouse.mouse_id)

      case Git.delete_branch(context.checkout, plan.branch) do
        :ok -> :removed
        {:error, reason} -> {:removed, {:branch_kept, reason}}
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
