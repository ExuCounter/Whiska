defmodule Whiska.Statusline do
  @moduledoc """
  The two lines Whiska draws for the person, each in the one place it belongs
  (ADR-0048).

  `summary/1` and `render/1` are **herdr's tab bar**, and the only line this
  module draws: the owl's state, always,
  and what is waiting anywhere on the machine, drawn once for the whole herdr
  session. Machine-wide, and only two segments: the tab bar is a whole-window
  surface, and a line whose meaning changed as the person switched workspaces
  would be the confusing option.

  What each mouse of a repo is doing is a line under its own workspace in
  herdr's sidebar (`Whiska.Sidebar`, ADR-0082), which the owl reports to herdr
  itself.

  On the tab bar:

  - **The owl** is always shown — `🦉 watching` or `🦉 owl down` — because a
    blank line could not be told apart from Whiska being broken (ADR-0027,
    second addendum). Up means in the process table (`Whiska.Owl.pids/0`, the
    doctor's probe, shared so the two cannot disagree) *and* collecting: an
    entry uncollected past the backstop still means down, whatever the process
    table says. Delivery cannot report its own outage, so this is the only
    place the outage can appear — and it still works, because the line is
    drawn by herdr's server rather than by the owl. herdr's script asks the
    owl for this line over its socket (`Whiska.Owl.Answers`); the owl that
    answers is up by definition, so only the backstop half applies there, and
    the script says down itself when nothing answers.
  - **Waiting** is `Whiska.Waiting`' own listing, every recorded house's open
    and sent questions plus the entries still on its doorstep, so the line and
    `whiska waiting` can never disagree about what "waiting" means. One thing
    is named by its mouse's branch, several become a count (ADR-0027's
    one-or-many rule, counted by whiska, not by question). Nothing waiting adds
    no segment.

  `Whiska.Waiting` reads the open-houses record with `read/1` rather than
  `open/2`: something already recorded, or already on a doorstep, is waiting on
  the person whether or not an owl is awake to collect it, and a dead owl is
  exactly when this line matters most.

  Nothing here writes, and no house is created.
  """

  alias Whiska.Delivery.Mode
  alias Whiska.Owl
  alias Whiska.Questions
  alias Whiska.Waiting

  @type summary :: %{
          owl: :watching | :down,
          away?: boolean(),
          waiting: [Waiting.entry()]
        }

  @doc """
  Everything the line needs, for the whole machine.

  Options are `Whiska.Waiting.list/1`'s — `:open_houses`, the record's path,
  `:away_path`, the away file, and `:now` — plus `:owl_pids`, the function
  that finds running owls, `Whiska.Owl.pids/0` unless a test pins it.
  """
  @spec summary(keyword()) :: summary()
  def summary(opts \\ []) do
    owl_pids = Keyword.get(opts, :owl_pids, &Owl.pids/0)
    waiting = Waiting.list(Keyword.delete(opts, :owl_pids))
    away? = Mode.away?(Keyword.get_lazy(opts, :away_path, &Mode.away_path/0))

    %{owl: owl_state(owl_pids.(), waiting), away?: away?, waiting: waiting}
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
  The line: the owl first, always, then away when the person is, then what
  waits. Never empty. Nothing per repo is on it — a focus, a held mouse — since
  the bar is one line for the whole machine.
  """
  @spec render(summary(), keyword()) :: String.t()
  def render(%{owl: owl, waiting: waiting} = summary, opts \\ []) do
    waits = waiting_segment(waiting)

    [owl_segment(owl), away_segment(Map.get(summary, :away?, false)), waits, hint(waits, opts)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  # The key the person bound to reach what waits, as they wrote it in their own
  # herdr entry: Whiska never reads their keybindings (ADR-0048). Shown only
  # beside something to reach.
  defp hint(nil, _opts), do: nil

  defp hint(_waits, opts) do
    case Keyword.get(opts, :hint) do
      hint when is_binary(hint) and hint != "" -> hint
      _none -> nil
    end
  end

  defp owl_segment(:watching), do: "🦉 watching"
  defp owl_segment(:down), do: "🦉 owl down"

  defp away_segment(true), do: "away"
  defp away_segment(false), do: nil

  # Counted by whiska, not by question: the person jumps to a whiska, never
  # straight to a mouse (ADR-0043), so what the bar answers is "how many places
  # need me", and two questions in one repo are one place. One is named by its
  # repo, several are a count (ADR-0027's one-or-many rule, ADR-0048 note). A
  # held mouse's question is not a place that needs them: they parked it.
  defp waiting_segment(waiting) do
    case waiting |> Enum.reject(& &1.held?) |> Enum.map(& &1.repo) |> Enum.uniq() do
      [] -> nil
      [one] -> "🐱 #{one}"
      repos -> "🐱 #{length(repos)} whiskas"
    end
  end
end
