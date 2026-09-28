defmodule Whiska.Owl.Nudge do
  @moduledoc """
  The nudge (ADR-0041): one line typed into every *other* open house's main
  session when a house gains something that waits on the person.

  Claude Code redraws a session's statusline only when that session's own
  conversation changes, so an idle main session in another repo never learns
  that a question opened here — the statusline's elsewhere segment (ADR-0027)
  is invisible exactly where it matters. The nudge is the smallest conversation
  change that forces the redraw. It is a notice, not a question: it is never
  recorded, awaits no answer, and holds no delivery slot (ADR-0008 addendum).

  ## How it works

  After each collection a house reports whether it has something open that
  qualifies — an open or sent question that is not a `done` report. On the
  change from nothing to something, this process asks every other house in the
  open-houses record (ADR-0039) to type one line; each target runs its own
  idle-and-slot gate (`Whiska.Owl.House.nudge/2`) and either types or holds.
  A held nudge is not retried: the next keystroke in that pane redraws the
  statusline anyway. The line names every source house with something open at
  that moment, never the target itself.

  Which panes were told is remembered per source and forgotten when the source
  reports nothing open, so a house that stays open nudges once per episode.
  Houses never call each other; only this process reaches across them.
  """

  use GenServer

  alias Whiska.Delivery.Text
  alias Whiska.OpenHouses
  alias Whiska.Owl
  alias Whiska.Owl.House

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  A house's word, after a collection, on whether it has something open that
  waits on the person. Sent to the named Nudge; a house running outside an owl
  has nobody to tell, and that is fine.
  """
  @spec report(GenServer.server(), Path.t(), boolean()) :: :ok
  def report(nudge \\ __MODULE__, main_checkout, open?) do
    GenServer.cast(nudge, {:report, Path.expand(main_checkout), open?})
  end

  @doc "Wait until every report sent so far has been acted on."
  @spec sync(GenServer.server()) :: :ok
  def sync(nudge \\ __MODULE__), do: GenServer.call(nudge, :sync)

  @impl true
  def init(_opts), do: {:ok, %{sources: %{}}}

  @impl true
  def handle_call(:sync, _from, state), do: {:reply, :ok, state}

  @impl true
  def handle_cast({:report, main, false}, state) do
    {:noreply, %{state | sources: Map.delete(state.sources, main)}}
  end

  def handle_cast({:report, main, true}, state) do
    if Map.has_key?(state.sources, main) do
      {:noreply, state}
    else
      told = tell_others(main, state.sources)
      {:noreply, %{state | sources: Map.put(state.sources, main, told)}}
    end
  end

  # Every other open house is asked once; the panes that typed are what this
  # source is remembered by.
  defp tell_others(source, sources) do
    waiting = [source | Map.keys(sources)]

    OpenHouses.read()
    |> Enum.reject(&(&1 == source))
    |> Enum.flat_map(fn target ->
      line = waiting |> Enum.reject(&(&1 == target)) |> Text.nudge()

      case nudge_house(target, line) do
        {:ok, pane} -> [pane]
        :held -> []
      end
    end)
    |> MapSet.new()
  end

  defp nudge_house(target, line) do
    case Owl.house(target) do
      {:ok, pid} -> House.nudge(pid, line)
      {:error, :shut} -> :held
    end
  catch
    # The house went away between the lookup and the call.
    :exit, _ -> :held
  end
end
