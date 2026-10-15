defmodule Whiska.ReviewStart do
  @moduledoc """
  A fresh mouse for a merge request's review, on a branch with no live one
  (ADR-0044's fifth exception, ADR-0060).

  It runs where the branch's mouse ran, and under its id, so the merge
  request, the owl's read of it and its questions stay that mouse's. A
  worktree still there is opened as it is; one dropped is made again at
  `worktrees/<branch>` from the branch fetched from `origin` (`Git.add_worktree/3`), and
  only there, so a worktree the person put elsewhere is never made for them.
  herdr opens it without moving the person's view. Then it is shaped as a
  build mouse on sonnet at medium effort with the review brief, its letter is
  written, and Claude starts on the one line naming it. The mouse is recorded
  alive once Claude runs, so a start that fails before is tried again, and a
  Claude that never took its line is woken like any live mouse.
  """

  alias Whiska.Git
  alias Whiska.Layout
  alias Whiska.Letters
  alias Whiska.Marker
  alias Whiska.MousePane
  alias Whiska.ReviewRound
  alias Whiska.Schema.Mouse
  alias Whiska.Shape
  alias Whiska.Spawn
  alias Whiska.Storage

  @shape ["build", "--model", "sonnet", "--effort", "medium"]

  @doc """
  Start a mouse in `mouse`'s worktree with `letter` to read. Answers its pane
  and the letter's path, or why it did not start.
  """
  @spec run(Path.t(), Mouse.t(), String.t(), %{herdr: module(), socket: Path.t()}) ::
          {:ok, %{pane: String.t(), letter: Path.t()}} | {:error, term()}
  def run(main_checkout, %Mouse{} = mouse, letter, via) do
    {:ok, shape} = Shape.parse(@shape)

    with {:ok, path} <- worktree(main_checkout, mouse),
         {:ok, opened} <- via.herdr.open_worktree(via.socket, path, false),
         :ok <- no_agent(via, opened, %{mouse | path: path}),
         {:ok, layout} <- Layout.resolve(path),
         {:ok, shaped} <- Spawn.shape(mouse.mouse_id, layout, shape, "review"),
         :ok <- Spawn.carry_hooks(main_checkout, layout.worktree_root),
         {:ok, letter} <- Letters.write(main_checkout, layout.worktree_root, letter),
         {:ok, _argv} <-
           via.herdr.start_agent(
             via.socket,
             opened.pane_id,
             Spawn.agent_name(mouse.branch),
             shaped.flags
           )
           |> or_take_back(letter),
         {:ok, _} <- Storage.revive(mouse.mouse_id, layout.worktree_root, opened.pane_id),
         :ok <-
           via
           |> Spawn.hand_over(opened.pane_id, Spawn.lead_in() <> ReviewRound.line(letter))
           |> or_take_back(letter) do
      {:ok, %{pane: opened.pane_id, letter: letter}}
    end
  end

  # A letter no session was handed is taken back: the review stays kept, and
  # the next round writes its own.
  defp or_take_back({:error, _} = error, letter) do
    File.rm(letter)
    error
  end

  defp or_take_back(ok, _letter), do: ok

  # A worktree herdr already had open may have a session the person started
  # there by hand; a second one in the same worktree is never started.
  defp no_agent(_via, %{already_open?: false}, _mouse), do: :ok

  defp no_agent(via, _opened, mouse) do
    case via.herdr.list_panes(via.socket) do
      {:ok, panes} ->
        if MousePane.agent_panes(mouse, panes) == [], do: :ok, else: {:error, :agent_running}

      {:error, _} = error ->
        error
    end
  end

  defp worktree(main_checkout, %Mouse{path: path} = mouse) when is_binary(path) do
    if File.dir?(path), do: ours(path, mouse), else: make_again(main_checkout, mouse)
  end

  defp worktree(_main_checkout, _mouse), do: {:error, :no_worktree}

  defp ours(path, mouse) do
    case Marker.read_id(path) do
      {:ok, id} when id == mouse.mouse_id -> {:ok, path}
      _other -> {:error, :not_this_mouse}
    end
  end

  defp make_again(main_checkout, %Mouse{branch: branch, path: path} = mouse)
       when is_binary(branch) do
    spawned = Path.join([main_checkout, "worktrees", branch])

    with true <-
           Layout.canonical(path) == Layout.canonical(spawned) || {:error, :not_where_spawned},
         :ok <- fetch(main_checkout, branch),
         :ok <- Git.add_worktree(main_checkout, spawned, branch),
         :ok <- Marker.write(spawned, mouse.mouse_id) do
      {:ok, spawned}
    end
  end

  defp make_again(_main_checkout, _mouse), do: {:error, :no_branch}

  # A branch still here is the one checked out, so `origin` going unanswered
  # leaves it as good as it was.
  defp fetch(main_checkout, branch) do
    case Git.fetch_branch(main_checkout, branch) do
      :ok -> :ok
      {:error, _} = error -> if branch_here?(main_checkout, branch), do: :ok, else: error
    end
  end

  defp branch_here?(main_checkout, branch),
    do: match?({:ok, _}, Git.branch_head(main_checkout, branch))
end
