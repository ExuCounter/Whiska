defmodule Whiska.Statusline do
  @moduledoc """
  The two lines Whiska draws for the person, each in the one place it belongs
  (ADR-0048).

  `summary/1` and `render/1` are **herdr's tab bar**: the owl's state, always,
  and what is waiting anywhere on the machine, drawn once for the whole herdr
  session. Machine-wide, and only two segments: the tab bar is a whole-window
  surface, and a line whose meaning changed as the person switched workspaces
  would be the confusing option.

  `house/2` and `render_house/1` are **one repo's Claude Code statusline**:
  what is waiting in this house and how many mice are alive here. No owl on it
  — the owl's state is machine-wide, it has the tab bar, and a per-session copy
  of it is what ADR-0048 undid. This line is empty when the repo is quiet: the
  person's own global statusline is still drawn underneath it, so an empty
  Whiska part reads as "nothing here", not as a blank screen.

  On the tab bar:

  - **The owl** is always shown — `🦉 watching` or `🦉 owl down` — because a
    blank line could not be told apart from Whiska being broken (ADR-0027,
    second addendum). Up means in the process table (`Whiska.Owl.pids/0`, the
    doctor's probe, shared so the two cannot disagree) *and* collecting: an
    entry uncollected past the backstop still means down, whatever the process
    table says. Delivery cannot report its own outage, so this is the only
    place the outage can appear — and it still works, because the line is
    drawn by herdr's server rather than by the owl.
  - **Waiting** is `Whiska.Waiting`' own listing, every recorded house's open
    and sent questions plus the entries still on its doorstep, so the line and
    `whiska waiting` can never disagree about what "waiting" means. One thing
    is named by its mouse's branch, several become a count (ADR-0027's
    one-or-many rule, counted by whiska, not by question). Nothing waiting adds
    no segment.

  The repo-scoped line follows the same one-or-many rule, over this house's own
  waiting entries: one is named by its mouse's branch, several become a count.

  The tab bar has no mice segment: herdr's own sidebar already shows every
  agent pane and its state, and repeating it on herdr's own tab bar is noise
  (ADR-0048). The repo-scoped line does, because a Claude session has no
  sidebar in view. Mice are counted from herdr rather than from the house: the
  house's `died_at` is only set while the owl runs, and this line must keep
  working when the owl is down.

  Neither has an elsewhere segment: the tab bar covers the whole machine, and
  the repo-scoped line is deliberately about this repo alone.

  `Whiska.Waiting` reads the open-houses record with `read/1` rather than
  `open/2`: something already recorded, or already on a doorstep, is waiting on
  the person whether or not an owl is awake to collect it, and a dead owl is
  exactly when this line matters most.

  Nothing here writes, and no house is created.
  """

  alias Whiska.Herdr
  alias Whiska.Layout
  alias Whiska.Owl
  alias Whiska.Questions
  alias Whiska.Waiting

  @type summary :: %{
          owl: :watching | :down,
          waiting: [Waiting.entry()]
        }

  @typedoc "`mice` is `nil` when herdr could not be asked."
  @type house_summary :: %{
          waiting: [Waiting.entry()],
          mice: non_neg_integer() | nil
        }

  @doc """
  Everything the line needs, for the whole machine.

  Options are `Whiska.Waiting.list/1`'s — `:open_houses`, the record's path,
  and `:now` — plus `:owl_pids`, the function that finds running owls,
  `Whiska.Owl.pids/0` unless a test pins it.
  """
  @spec summary(keyword()) :: summary()
  def summary(opts \\ []) do
    owl_pids = Keyword.get(opts, :owl_pids, &Owl.pids/0)
    waiting = Waiting.list(Keyword.delete(opts, :owl_pids))

    %{owl: owl_state(owl_pids.(), waiting), waiting: waiting}
  end

  # Up means in the process table and collecting: an entry left on a doorstep
  # past the backstop is still "down", whatever pgrep says (ADR-0027). Anything
  # younger may just be the normal race between the two Stop hooks (ADR-0036).
  defp owl_state([], _waiting), do: :down

  defp owl_state(_pids, waiting) do
    if Enum.any?(waiting, &(&1.status == "doorstep" and &1.age_s > Questions.backstop_s())),
      do: :down,
      else: :watching
  end

  @doc """
  The line: the owl first, always, then what waits. Never empty.
  """
  @spec render(summary()) :: String.t()
  def render(%{owl: owl, waiting: waiting}) do
    [owl_segment(owl), waiting_segment(waiting)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp owl_segment(:watching), do: "🦉 watching"
  defp owl_segment(:down), do: "🦉 owl down"

  # Counted by whiska, not by question: the person jumps to a whiska, never
  # straight to a mouse (ADR-0043), so what the bar answers is "how many places
  # need me", and two questions in one repo are one place. One is named by its
  # repo, several are a count (ADR-0027's one-or-many rule, ADR-0048 note).
  defp waiting_segment([]), do: nil

  defp waiting_segment(waiting) do
    case waiting |> Enum.map(& &1.repo) |> Enum.uniq() do
      [one] -> "🐱 #{one}"
      repos -> "🐱 #{length(repos)} whiskas"
    end
  end

  @doc """
  Everything the repo-scoped line needs for the house whose main checkout this
  is.

  Options: `:herdr_socket` (defaults to `HERDR_SOCKET_PATH`); `nil`, or a herdr
  that cannot be asked, leaves `mice` as `nil` and the segment unsaid rather
  than guessed. `:now` is `Whiska.Waiting.house/2`'s.
  """
  @spec house(Path.t(), keyword()) :: house_summary()
  def house(main_checkout, opts \\ []) do
    main = Path.expand(main_checkout)
    socket = Keyword.get_lazy(opts, :herdr_socket, &Herdr.socket_path/0)

    %{waiting: Waiting.house(main, Keyword.take(opts, [:now])), mice: mice(socket, main)}
  end

  defp mice(nil, _main), do: nil

  defp mice(socket, main) do
    case Herdr.impl().list_panes(socket) do
      {:ok, panes} -> mice_here(panes, main)
      _unreachable -> nil
    end
  end

  @doc """
  How many of this repo's worktrees have a live agent pane in them. Pure.

  Both sides are canonicalised before they are compared, the way every other
  match between a pane and a worktree is (`Whiska.Layout.inside?/2`): herdr
  reports a pane's cwd with its symlinks resolved, and a repo reached through
  one would otherwise never match its own mice.
  """
  @spec mice_here([Herdr.pane()], Path.t()) :: non_neg_integer()
  def mice_here(panes, main_checkout) do
    main = Layout.canonical(main_checkout)

    panes
    |> Enum.filter(&(&1.agent != nil and is_binary(&1.cwd)))
    |> Enum.flat_map(fn pane ->
      case Layout.resolve(pane.cwd) do
        {:ok, %Layout{main_checkout: found, worktree_root: root}} ->
          if Layout.canonical(found) == main, do: [root], else: []

        _elsewhere ->
          []
      end
    end)
    |> Enum.uniq()
    |> length()
  end

  @doc """
  The repo-scoped line: what waits here, then what is running here. Empty when
  the repo is quiet.
  """
  @spec render_house(house_summary()) :: String.t()
  def render_house(%{waiting: waiting, mice: mice}) do
    [here_segment(waiting), mice_segment(mice)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  # Counted by branch, not by question: at most one question per mouse is ever
  # open (ADR-0037), and a mouse is the place the answer goes back to.
  defp here_segment([]), do: nil

  defp here_segment(waiting) do
    case waiting |> Enum.map(& &1.branch) |> Enum.uniq() do
      [one] -> "🐱 #{one}"
      branches -> "🐱 #{length(branches)} waiting"
    end
  end

  defp mice_segment(nil), do: nil
  defp mice_segment(0), do: nil
  defp mice_segment(1), do: "🐭 1 mouse"
  defp mice_segment(n), do: "🐭 #{n} mice"
end
