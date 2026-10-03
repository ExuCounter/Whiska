defmodule Whiska.Pickup do
  @moduledoc """
  Carrying on a turn that died (ADR-0065).

  One pass over this house's mice, run from the backstop beside the cleanup
  sweep. A turn ends by reaching the doorstep (ADR-0036), so a mouse that was
  seen working, has gone quiet, and has left nothing behind is a mouse whose
  turn ended without finishing — the session is still sitting there with its
  whole context and an error on the screen, and from the outside it is
  indistinguishable from a branch quietly working.

  The owl types one short line into that mouse's own pane and nothing else.
  Never the original prompt: the session still knows what it did, and re-asking
  risks redoing a file already written or a commit already made.

  **One attempt per died turn.** A pickup that produces no finished turn is
  never repeated — the branch is ADR-0026's stuck mouse from then on, which is
  where the rest of that ladder lives. A turn that does finish earns the branch
  another pickup the next time one dies, which is not a loop: a finished turn
  stands between every two.

  **Unknown is never permission**, the same rule cleanup runs on (ADR-0061). A
  pane herdr cannot classify, a worktree with no pane or with two, a herdr that
  will not answer — every one of them leaves the branch alone.

  ## Why a settling window

  A laptop waking brings herdr's socket back with everything else, and for a
  moment the owl's picture of every pane is whatever reconnection happened to
  produce. A mouse is only picked up once its pane has been reported ready for
  `settle_ms` across separate sweeps, so a reconnect storm cannot read a whole
  fleet of branches as having died at once. herdr failing to answer throws the
  clocks away, so they start again rather than counting through a gap.
  """

  alias Whiska.Delivery.Draft
  alias Whiska.Doorstep
  alias Whiska.Layout
  alias Whiska.Schema.Mouse
  alias Whiska.Schema.Question
  alias Whiska.Storage

  @ready ~w(idle done)
  @waiting ~w(open sent)

  @typedoc """
  What the owl remembers about one mouse's pane between sweeps: herdr's last
  word on it, and since when it has been ready for input.
  """
  @type look :: %{status: String.t(), ready_since: DateTime.t() | nil}

  @typedoc "That memory, by mouse. The owl's, not the database's."
  @type seen :: %{String.t() => look()}

  @typedoc "What one sweep did about one mouse."
  @type outcome :: :picked_up | {:left, atom() | {:refused, term()}}

  @doc """
  The line the owl types. One sentence of fact and one caution, and no decision
  of any kind — the session is told what happened to it, never what to do
  differently (ADR-0026).
  """
  @spec line() :: String.t()
  def line do
    "Your last turn ended on an error before it finished. Carry on from where " <>
      "you stopped, and check what you already did before redoing any of it."
  end

  @doc """
  One pass over every mouse of this house, returning what became of each and
  the pane memory the next sweep starts from.

  Keys: `:main_checkout`, `:herdr`, `:socket`, `:panes` (herdr's last full
  answer, which the house already holds), `:seen` (the previous pass's
  memory), `:settle_ms`, `:now`.

  herdr is not asked for its panes here. The house re-lists them on the same
  backstop to match mice and judge liveness (ADR-0026), and a second list a
  moment later would be a second answer to the same question.
  """
  @spec sweep(map()) :: {[{String.t(), outcome()}], seen()}
  def sweep(%{panes: {:ok, panes}} = house), do: run(house, panes)
  def sweep(_no_panes), do: {[], %{}}

  defp run(house, panes) do
    mice = Enum.reject(Storage.alive_mice(), & &1.removed_at)

    local = %{
      questions: Enum.group_by(Storage.all(Question), & &1.mouse_id),
      doorstep: doorstep(house.main_checkout)
    }

    {judged, seen} =
      Enum.map_reduce(mice, %{}, fn mouse, seen ->
        {look, pane} = observe(mouse, panes, house)

        {{mouse, pane, verdict(mouse, look, pane, local, house)},
         Map.put(seen, mouse.mouse_id, look)}
      end)

    {Enum.map(judged, fn {mouse, pane, v} -> {mouse.mouse_id, act(mouse, pane, v, house)} end),
     seen}
  end

  # herdr's word on this mouse's pane, folded into what the last sweep saw.
  # Stamping `worked_at` here rather than on every sighting of a working pane
  # is what keeps a turn that ended cleanly from reading as one that died: the
  # stamp marks a turn *starting*, so herdr still calling a pane working a
  # second after its entry landed moves nothing.
  defp observe(mouse, panes, house) do
    was = Map.get(house.seen, mouse.mouse_id)

    case agent_panes(mouse, panes) do
      [pane] -> {seen_pane(mouse, pane, was, house), pane}
      [] -> {%{status: "no pane", ready_since: nil}, nil}
      _many -> {%{status: "many panes", ready_since: nil}, nil}
    end
  end

  defp seen_pane(mouse, %{agent_status: "working"}, was, house) do
    unless was && was.status == "working", do: Storage.set_working(mouse.mouse_id, house.now)
    %{status: "working", ready_since: nil}
  end

  defp seen_pane(_mouse, %{agent_status: status}, was, house) when status in @ready do
    %{status: status, ready_since: carried(was) || house.now}
  end

  defp seen_pane(_mouse, %{agent_status: status}, _was, _house) do
    %{status: status, ready_since: nil}
  end

  defp carried(%{status: status, ready_since: since}) when status in @ready, do: since
  defp carried(_otherwise), do: nil

  defp agent_panes(%Mouse{path: path}, panes) when is_binary(path) do
    Enum.filter(panes, &(&1.agent != nil and is_binary(&1.cwd) and Layout.inside?(&1.cwd, path)))
  end

  defp agent_panes(_no_path, _panes), do: []

  # The checks run cheapest first and the first to refuse is the answer, so a
  # reason names the nearest thing standing in the way rather than the worst.
  defp verdict(mouse, look, pane, local, house) do
    with :ok <- standing(mouse),
         :ok <- turn_died(mouse, local),
         :ok <- nothing_waiting(mouse, local),
         :ok <- one_attempt(mouse, local),
         :ok <- quiet_long_enough(look, house),
         do: claude?(pane)
  end

  defp standing(%Mouse{path: path}) do
    if is_binary(path) and File.dir?(path), do: :ok, else: {:leave, :gone}
  end

  defp turn_died(%Mouse{worked_at: nil}, _local), do: {:leave, :never_worked}

  defp turn_died(%Mouse{mouse_id: id, worked_at: worked_at}, local) do
    cond do
      Enum.any?(questions(local, id), &asked_since?(&1, worked_at)) -> {:leave, :finished}
      MapSet.member?(local.doorstep, id) -> {:leave, :uncollected}
      true -> :ok
    end
  end

  defp nothing_waiting(%Mouse{mouse_id: id}, local) do
    if Enum.any?(questions(local, id), &(&1.status in @waiting)),
      do: {:leave, :waiting},
      else: :ok
  end

  # The cap. A pickup that was followed by a turn reaching the doorstep did its
  # job and is spent; one that was not is this branch's one attempt, already
  # made.
  defp one_attempt(%Mouse{picked_up_at: nil}, _local), do: :ok

  defp one_attempt(%Mouse{mouse_id: id, picked_up_at: picked_up_at}, local) do
    if Enum.any?(questions(local, id), &asked_since?(&1, picked_up_at)),
      do: :ok,
      else: {:leave, :already}
  end

  defp questions(local, mouse_id), do: Map.get(local.questions, mouse_id, [])

  defp asked_since?(%Question{asked_at: asked_at}, stamp),
    do: DateTime.compare(asked_at, stamp) != :lt

  defp quiet_long_enough(%{status: status, ready_since: %DateTime{} = since}, house)
       when status in @ready do
    if DateTime.diff(house.now, since, :millisecond) >= house.settle_ms,
      do: :ok,
      else: {:leave, :settling}
  end

  defp quiet_long_enough(%{status: "no pane"}, _house), do: {:leave, :no_pane}
  defp quiet_long_enough(%{status: "many panes"}, _house), do: {:leave, :many_panes}
  defp quiet_long_enough(_still_going, _house), do: {:leave, :working}

  defp claude?(%{agent: "claude"}), do: :ok
  defp claude?(_other), do: {:leave, :no_claude}

  defp act(_mouse, _pane, {:leave, reason}, _house), do: {:left, reason}

  defp act(mouse, pane, :ok, house) do
    if typing?(pane, house), do: {:left, :typing}, else: nudge(mouse, pane, house)
  end

  # The second half of delivery's gate, asked of the mouse's pane for the same
  # reason (ADR-0047): herdr's idle is the model's word, and a line typed into
  # a box somebody is halfway through lands inside what they are writing. An
  # unreadable screen is an unavailable signal, so it types anyway.
  defp typing?(pane, house) do
    case house.herdr.read_screen(house.socket, pane.pane_id) do
      {:ok, screen} -> Draft.read(screen) == :typing
      {:error, _reason} -> false
    end
  end

  # The stamp goes down before the line does, and comes back up if herdr
  # refuses it. A cap that depended on a write landing *after* the owl had
  # already typed would be no cap on the one run where that write failed.
  defp nudge(%Mouse{mouse_id: id, picked_up_at: was}, pane, house) do
    Storage.set_picked_up(id, house.now)

    case house.herdr.prompt(house.socket, pane.pane_id, line()) do
      :ok ->
        :picked_up

      {:error, reason} ->
        Storage.set_picked_up(id, was)
        {:left, {:refused, reason}}
    end
  end

  defp doorstep(checkout) do
    checkout
    |> Doorstep.waiting()
    |> MapSet.new(fn {_file, entry} -> entry.mouse_id end)
  end
end
