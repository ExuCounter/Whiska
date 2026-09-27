defmodule Whiska.Statusline do
  @moduledoc """
  The one line the project statusline appends: the owl's state, always; the
  whiskas on the machine when there is more than one; the mice alive here; the
  questions waiting here; and the whiskas elsewhere with something waiting.

  Detail for one thing, a count for many, applied to each segment the same way
  (ADR-0027). The one exception is the owl, which is always shown — `🦉
  watching` or `🦉 owl down · N waiting` — because a blank line could not be
  told apart from Whiska being broken (ADR-0027, second addendum). The owl is
  up when it is in the process table (`Whiska.Owl.pids/0`, the doctor's probe)
  *and* the doorstep is being collected: an entry uncollected past the backstop
  still means down, whatever the process table says.

  The questions segment is `Whiska.Questions`' own, so the statusline and
  `whiska questions` can never disagree. The rest comes from one herdr
  `pane.list` call, the boundary ADR-0031 names:

  - **Mice here** are worktrees of this repo with a live agent pane in them —
    one per worktree (ADR-0023), whatever the pane count. herdr is the source
    of liveness, not the house: without the owl running, `died_at` is never
    set, and the statusline must work when the owl is down.
  - **Whiskas** are the houses the owl has open — the open-houses record,
    `Whiska.OpenHouses` (ADR-0039) — that have a live agent pane in their repo
    root. Their headcount is shown when it is more than one (`🐈 3 whiskas`);
    this repo counts while its house is open, whichever pane the line is
    drawn in. Every other one's house is read the way `whiska questions` reads
    this one, and it is shown apart only when something is waiting there: one
    is named by its folder, several become a count. A quiet laptop reads `🦉
    watching` and nothing more. A repo with a house file on disk but not open
    in the owl is not a whiska, live pane or not: nothing collects there.

  ADR-0025 routes cross-repo visibility through the owl's global socket. That
  socket is not built; until it is, the whiskas are read off the record and
  their live panes, and their houses read directly. The record is trusted only
  while an owl is in the process table (`Whiska.OpenHouses.open/2`): with the
  owl down, no house is open and the line says only that.

  Nothing here writes, and no house is created (`Whiska.Questions.summary/1`).
  """

  alias Whiska.Herdr
  alias Whiska.Layout
  alias Whiska.OpenHouses
  alias Whiska.Owl
  alias Whiska.Questions

  @type summary :: %{
          owl: :watching | :down,
          questions: Questions.summary(),
          whiskas: non_neg_integer() | nil,
          mice: non_neg_integer() | nil,
          elsewhere: [Path.t()]
        }

  @doc """
  Everything the line needs for the repo whose main checkout this is.

  Options: `:herdr_socket` (defaults to `HERDR_SOCKET_PATH`); `nil`, or a herdr
  that cannot be asked, leaves `whiskas` and `mice` as `nil` and `elsewhere`
  empty — the line then says only what the house and the process table know.
  `:owl_pids` is the function that finds running owls, `Whiska.Owl.pids/0`
  unless a test pins it; `:open_houses` is the record's path, the real one
  unless pinned.
  """
  @spec summary(Path.t(), keyword()) :: {:ok, summary()} | {:error, term()}
  def summary(main_checkout, opts \\ []) do
    main = Path.expand(main_checkout)
    socket = Keyword.get_lazy(opts, :herdr_socket, &Herdr.socket_path/0)
    owl_pids = Keyword.get(opts, :owl_pids, &Owl.pids/0)
    record = Keyword.get_lazy(opts, :open_houses, &OpenHouses.path/0)

    with {:ok, questions} <- Questions.summary(main) do
      pids = owl_pids.()
      owl = owl_state(pids, questions)
      open = OpenHouses.open(pids, record)

      case ask_herdr(socket) do
        {:ok, panes} ->
          whiskas = whiskas(panes, open)
          here = if main in open, do: [main], else: []

          elsewhere =
            whiskas
            |> Enum.reject(&(&1 == main))
            |> Enum.filter(&waiting?/1)

          {:ok,
           %{
             owl: owl,
             questions: questions,
             whiskas: length(Enum.uniq(here ++ whiskas)),
             mice: mice_here(panes, main),
             elsewhere: elsewhere
           }}

        _unreachable ->
          {:ok, %{owl: owl, questions: questions, whiskas: nil, mice: nil, elsewhere: []}}
      end
    end
  end

  # Up means in the process table and collecting: a doorstep left past the
  # backstop is still "down", whatever pgrep says (ADR-0027).
  defp owl_state([], _questions), do: :down
  defp owl_state(_pids, %{doorstep_stale: true}), do: :down
  defp owl_state(_pids, _questions), do: :watching

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
  The main checkouts with a live whiska: of the houses `open` (the record, as
  `Whiska.OpenHouses.open/2` allows it to be trusted), those with an agent pane
  in or beneath their repo root and not inside one of their worktrees. Pure.
  """
  @spec whiskas([Herdr.pane()], [Path.t()]) :: [Path.t()]
  def whiskas(panes, open) do
    panes
    |> agent_panes()
    |> Enum.flat_map(fn pane ->
      with {:error, :not_in_worktree} <- Layout.resolve(pane.cwd),
           {:ok, main} <- repo_root(pane.cwd),
           true <- main in open do
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
  The line: the owl first, always, since delivery cannot report its own outage
  and a blank line looks like Whiska being broken; then the whiskas on the
  machine when there is more than one, the mice here, the questions here, and
  what waits elsewhere. Never empty.
  """
  @spec render(summary()) :: String.t()
  def render(%{
        owl: owl,
        questions: questions,
        whiskas: whiskas,
        mice: mice,
        elsewhere: elsewhere
      }) do
    [
      owl_segment(owl, questions),
      whiskas_segment(whiskas),
      mice_segment(mice),
      Questions.questions_segment(questions),
      elsewhere_segment(elsewhere)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp owl_segment(:watching, _), do: "🦉 watching"
  defp owl_segment(:down, %{doorstep: doorstep}), do: "🦉 owl down · #{doorstep} waiting"

  defp whiskas_segment(n) when is_integer(n) and n > 1, do: "🐈 #{n} whiskas"
  defp whiskas_segment(_), do: nil

  defp mice_segment(nil), do: nil
  defp mice_segment(0), do: nil
  defp mice_segment(1), do: "🐭 1 mouse"
  defp mice_segment(n), do: "🐭 #{n} mice"

  defp elsewhere_segment([]), do: nil
  defp elsewhere_segment([one]), do: "⚡ #{Path.basename(one)} waiting"
  defp elsewhere_segment(many), do: "⚡ #{length(many)} whiskas waiting elsewhere"
end
