defmodule Whiska.Statusline do
  @moduledoc """
  The one line the project statusline appends: the owl, the mice alive here,
  the questions waiting here, and the whiskas elsewhere with something waiting.

  Detail for one thing, a count for many, applied to each segment the same way
  (ADR-0027). The questions segment is `Whiska.Questions`' own, so the
  statusline and `whiska questions` can never disagree. The rest comes from one
  herdr `pane.list` call, the boundary ADR-0031 names:

  - **Mice here** are worktrees of this repo with a live agent pane in them —
    one per worktree (ADR-0023), whatever the pane count. herdr is the source
    of liveness, not the house: without the owl running, `died_at` is never
    set, and the statusline must work when the owl is down.
  - **Whiskas** are live agent panes sitting in a repo root that has a house.
    Every other one's house is read the way `whiska questions` reads this one,
    and it is shown only when something is waiting there: one is named by its
    folder, several become a count. A quiet laptop adds nothing to the line.

  ADR-0025 routes cross-repo visibility through the owl's global socket. That
  socket is not built; until it is, the whiskas are found through their live
  panes and their houses read directly, which also keeps the count honest when
  the owl is down. A repo with no live whiska pane is invisible here — there is
  nobody there to answer anyway.

  Nothing here writes, and no house is created (`Whiska.Questions.summary/1`).
  """

  alias Whiska.Herdr
  alias Whiska.Layout
  alias Whiska.Questions
  alias Whiska.Storage

  @type summary :: %{
          questions: Questions.summary(),
          mice: non_neg_integer() | nil,
          elsewhere: [Path.t()]
        }

  @doc """
  Everything the line needs for the repo whose main checkout this is.

  Options: `:herdr_socket` (defaults to `HERDR_SOCKET_PATH`); `nil`, or a herdr
  that cannot be asked, leaves `mice` as `nil` and `elsewhere` empty — the line
  then says only what the house knows.
  """
  @spec summary(Path.t(), keyword()) :: {:ok, summary()} | {:error, term()}
  def summary(main_checkout, opts \\ []) do
    main = Path.expand(main_checkout)
    socket = Keyword.get_lazy(opts, :herdr_socket, &Herdr.socket_path/0)

    with {:ok, questions} <- Questions.summary(main) do
      case ask_herdr(socket) do
        {:ok, panes} ->
          elsewhere =
            panes
            |> whiskas()
            |> Enum.reject(&(&1 == main))
            |> Enum.filter(&waiting?/1)

          {:ok, %{questions: questions, mice: mice_here(panes, main), elsewhere: elsewhere}}

        _unreachable ->
          {:ok, %{questions: questions, mice: nil, elsewhere: []}}
      end
    end
  end

  defp ask_herdr(nil), do: :no_socket
  defp ask_herdr(socket), do: Herdr.impl().list_panes(socket)

  defp waiting?(main) do
    case Questions.summary(main) do
      {:ok, %{open: open, doorstep: doorstep}} -> open != [] or doorstep > 0
      {:error, _} -> false
    end
  end

  @doc "How many of this repo's worktrees have a live agent pane in them. Pure."
  @spec mice_here([Herdr.pane()], Path.t()) :: non_neg_integer()
  def mice_here(panes, main_checkout) do
    main = Path.expand(main_checkout)

    panes
    |> agent_panes()
    |> Enum.flat_map(fn pane ->
      case Layout.resolve(pane.cwd) do
        {:ok, %Layout{main_checkout: ^main, worktree_root: root}} -> [root]
        _ -> []
      end
    end)
    |> Enum.uniq()
    |> length()
  end

  @doc """
  The main checkouts with a live whiska: an agent pane in (or beneath) a repo
  root that has a house, and not inside one of its worktrees. Pure apart from
  looking for the house on disk.
  """
  @spec whiskas([Herdr.pane()]) :: [Path.t()]
  def whiskas(panes) do
    panes
    |> agent_panes()
    |> Enum.flat_map(fn pane ->
      with {:error, :not_in_worktree} <- Layout.resolve(pane.cwd),
           {:ok, main} <- repo_root(pane.cwd),
           true <- File.exists?(Storage.database_path(main)) do
        [main]
      else
        _ -> []
      end
    end)
    |> Enum.uniq()
  end

  defp agent_panes(panes), do: Enum.filter(panes, &(&1.agent != nil and is_binary(&1.cwd)))

  # Walk up from `cwd` to the nearest directory holding a `.git`.
  defp repo_root(cwd) do
    cwd
    |> Path.expand()
    |> Stream.unfold(fn
      nil -> nil
      "/" -> {"/", nil}
      dir -> {dir, Path.dirname(dir)}
    end)
    |> Enum.find_value({:error, :not_a_repo}, fn dir ->
      if File.exists?(Path.join(dir, ".git")), do: {:ok, dir}
    end)
  end

  @doc """
  The line: the owl first, since delivery cannot report its own outage; then
  the mice here, the questions here, and what waits elsewhere. Empty when there
  is nothing to say.
  """
  @spec render(summary()) :: String.t()
  def render(%{questions: questions, mice: mice, elsewhere: elsewhere}) do
    [
      Questions.owl_segment(questions),
      mice_segment(mice),
      Questions.questions_segment(questions),
      elsewhere_segment(elsewhere)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp mice_segment(nil), do: nil
  defp mice_segment(0), do: nil
  defp mice_segment(1), do: "🐭 1 mouse"
  defp mice_segment(n), do: "🐭 #{n} mice"

  defp elsewhere_segment([]), do: nil
  defp elsewhere_segment([one]), do: "⚡ #{Path.basename(one)} waiting"
  defp elsewhere_segment(many), do: "⚡ #{length(many)} whiskas waiting elsewhere"
end
