defmodule Whiska.Owl.House do
  @moduledoc """
  One open house: a project's home, with its lights on.

  A house exists on disk from the first invocation onwards and is never destroyed
  (ADR-0003); this process is what it means for it to be *open*. While it runs,
  the house holds its own database connection, keeps its herdr subscription up,
  and collects its doorstep. Shutting it stops all three and touches nothing on
  disk.

  ## What the house watches

  The house learns which herdr panes are its mice by matching each pane's `cwd`
  to a mouse record's worktree path — at open, and again whenever herdr reports a
  new agent pane. That is the first and only thing that ever fills a mouse's
  `pane` column (ADR-0006). A mouse with no pane anywhere is dead (ADR-0026), and
  is marked, never deleted (ADR-0007).

  herdr's `pane.agent_status_changed` subscription is per pane, so the house
  subscribes for each mouse pane it knows, plus the global `pane.closed`,
  `pane.exited` and `pane.agent_detected`. When the set of mouse panes changes
  the subscription is reopened with the new set; when herdr drops it, it is
  reopened after a short wait, and kept being retried while herdr is down.

  ## Collection (ADR-0036)

  Three triggers, only one of them a timer: a mouse pane going idle, opening the
  house, and a slow backstop. Each one reads the doorstep, records every entry as
  a question — classified by its marker alone (ADR-0009) — and marks the entry
  collected. A `done` report is delivered like any other and closed the moment
  it is sent; an entry whose worktree is no longer on disk is recorded as
  orphaned rather than delivered. Whatever a mouse
  leaves supersedes its own earlier open or sent questions: it has moved past
  them, and an answer could no longer land.

  ## Delivery (ADR-0008)

  A question reaches the main session — the pane `whiska start` recorded
  (ADR-0020) — only when that pane runs Claude and reports idle, and no other
  question is already out waiting for its answer. Anything else joins the queue
  silently. The one exception is the first question of a fresh round, which
  waits `round_wait_ms` (8 s) so that the line it delivers carries an accurate
  count of what landed just behind it. Delivery is attempted after every
  collection, whenever herdr reports the main pane idle, and on the backstop.

  herdr's word is taken fresh at each attempt (`pane.get`), not from the last
  event: `claude` + `idle` delivers; `working` or `blocked` holds; `claude` +
  `unknown` delivers anyway and says so in the line, since holding would be
  silence with no explanation; no agent at all is a dead pane, held with a
  warning. What is typed is one line (`Whiska.Delivery.Text`), not the message.
  """

  use GenServer

  alias Whiska.Delivery.Text
  alias Whiska.Doorstep
  alias Whiska.Herdr
  alias Whiska.Layout
  alias Whiska.Question.Marker
  alias Whiska.Schema.Mouse
  alias Whiska.Schema.Question
  alias Whiska.Storage

  @global_subscriptions [
    %{type: "pane.closed"},
    %{type: "pane.exited"},
    %{type: "pane.agent_detected"}
  ]

  @default_backstop_ms 60_000
  @default_resubscribe_ms 5_000
  @default_round_wait_ms 8_000

  defstruct [
    :main_checkout,
    :socket,
    :herdr,
    :repo,
    :backstop_ms,
    :resubscribe_ms,
    :round_wait_ms,
    subscription: nil,
    panes: %{},
    main_pane: nil,
    round_timer: nil,
    warned: MapSet.new()
  ]

  # -- API ---------------------------------------------------------------------

  @doc """
  Open a house.

  Options: `:main_checkout` (required), `:herdr_socket` (defaults to
  `HERDR_SOCKET_PATH`), `:backstop_ms`, `:resubscribe_ms`, `:round_wait_ms`,
  `:name`.
  """
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @doc "Collect this house's doorstep now. Returns how many entries were collected."
  @spec collect(GenServer.server()) :: {:ok, non_neg_integer()}
  def collect(house), do: GenServer.call(house, :collect)

  @doc "Ask herdr for its panes again and re-match mice to them."
  @spec reconcile(GenServer.server()) :: :ok
  def reconcile(house), do: GenServer.call(house, :reconcile)

  @doc "Wait until everything sent to the house so far has been handled."
  @spec sync(GenServer.server()) :: :ok
  def sync(house), do: GenServer.call(house, :sync)

  @doc "The pid of this house's Repo instance, for code that wants to read it."
  @spec repo(GenServer.server()) :: pid()
  def repo(house), do: GenServer.call(house, :repo)

  @doc "This house's main checkout."
  @spec main_checkout(GenServer.server()) :: Path.t()
  def main_checkout(house), do: GenServer.call(house, :main_checkout)

  # -- lifecycle ---------------------------------------------------------------

  @impl true
  def init(opts) do
    # Trapping exits is what makes terminate/2 run on shutdown, and what turns
    # the subscription process ending into a message rather than our own death.
    Process.flag(:trap_exit, true)
    main = Keyword.fetch!(opts, :main_checkout)

    case Storage.open(main, name: nil) do
      {:ok, repo} ->
        state = %__MODULE__{
          main_checkout: main,
          socket: Keyword.get(opts, :herdr_socket) || Herdr.socket_path(),
          herdr: Herdr.impl(),
          repo: repo,
          backstop_ms: Keyword.get(opts, :backstop_ms, @default_backstop_ms),
          resubscribe_ms: Keyword.get(opts, :resubscribe_ms, @default_resubscribe_ms),
          round_wait_ms: Keyword.get(opts, :round_wait_ms, @default_round_wait_ms),
          main_pane: Storage.main_pane()
        }

        {:ok, state, {:continue, :open}}

      {:error, reason} ->
        {:stop, {:cannot_open_house, reason}}
    end
  end

  @impl true
  def handle_continue(:open, state) do
    state =
      state
      |> reconcile_panes()
      |> subscribe()
      |> collect_now()

    Process.send_after(self(), :backstop, state.backstop_ms)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    drop_subscription(state)
    Storage.close(state.repo)
    :ok
  end

  # -- calls -------------------------------------------------------------------

  @impl true
  def handle_call(:collect, _from, state) do
    {collected, state} = collect_and_count(state)
    {:reply, {:ok, collected}, state}
  end

  def handle_call(:reconcile, _from, state), do: {:reply, :ok, refresh(state)}
  def handle_call(:sync, _from, state), do: {:reply, :ok, state}
  def handle_call(:repo, _from, state), do: {:reply, state.repo, state}
  def handle_call(:main_checkout, _from, state), do: {:reply, state.main_checkout, state}

  # -- herdr events ------------------------------------------------------------

  @impl true
  def handle_info({:herdr_event, "pane_agent_status_changed", data}, state) do
    case data do
      %{"pane_id" => pane_id, "agent_status" => status}
      when status in ["idle", "done"] and pane_id == state.main_pane and pane_id != nil ->
        # The person is free: the next question can go, unless a fresh round is
        # still gathering its count.
        {:noreply, deliver(state)}

      %{"pane_id" => pane_id, "agent_status" => "idle"} ->
        if Map.has_key?(state.panes, pane_id),
          do: {:noreply, collect_now(state)},
          else: {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:herdr_event, gone, %{"pane_id" => pane_id}}, state)
      when gone in ["pane_closed", "pane_exited"] do
    case Map.pop(state.panes, pane_id) do
      {nil, _} ->
        {:noreply, state}

      {mouse_id, panes} ->
        Storage.mark_dead(mouse_id)
        {:noreply, resubscribe(%{state | panes: panes})}
    end
  end

  def handle_info({:herdr_event, "pane_agent_detected", _data}, state) do
    {:noreply, refresh(state)}
  end

  def handle_info({:herdr_event, _other, _data}, state), do: {:noreply, state}

  def handle_info({:herdr_subscription_lost, reason}, state) do
    warn(state, "herdr subscription lost (#{inspect(reason)}) — will reopen it")
    {:noreply, schedule_resubscribe(%{state | subscription: nil})}
  end

  def handle_info(:resubscribe, state), do: {:noreply, subscribe(state)}

  def handle_info(:backstop, state) do
    state = state |> refresh() |> collect_now() |> deliver()
    Process.send_after(self(), :backstop, state.backstop_ms)
    {:noreply, state}
  end

  def handle_info(:round_over, state) do
    {:noreply, deliver(%{state | round_timer: nil})}
  end

  # The subscription process ending normally has already been announced by its
  # own message. Anything else linked to us dying is a reason to stop.
  def handle_info({:EXIT, pid, _reason}, %{subscription: pid} = state), do: {:noreply, state}
  def handle_info({:EXIT, _pid, :normal}, state), do: {:noreply, state}
  def handle_info({:EXIT, _pid, :shutdown}, state), do: {:noreply, state}

  def handle_info({:EXIT, pid, reason}, %{repo: pid} = state),
    do: {:stop, {:repo_down, reason}, state}

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  # -- panes and the subscription ----------------------------------------------

  # Re-list panes, re-read the main session, and reopen the subscription if
  # the set of panes to watch changed.
  defp refresh(state) do
    before = {Map.keys(state.panes), state.main_pane}
    state = %{reconcile_panes(state) | main_pane: Storage.main_pane()}
    after_ = {Map.keys(state.panes), state.main_pane}
    if after_ == before, do: state, else: resubscribe(state)
  end

  defp reconcile_panes(%{socket: nil} = state) do
    warn(state, "no herdr socket known — mice cannot be matched to panes")
    state
  end

  defp reconcile_panes(state) do
    case state.herdr.list_panes(state.socket) do
      {:ok, panes} ->
        agent_panes = Enum.filter(panes, &(&1.agent != nil and is_binary(&1.cwd)))
        mice = Storage.all(Mouse)

        matched =
          for mouse <- mice,
              pane = Enum.find(agent_panes, &Layout.inside?(&1.cwd, mouse.path)),
              pane != nil,
              into: %{} do
            Storage.set_pane(mouse.mouse_id, pane.pane_id)
            {pane.pane_id, mouse.mouse_id}
          end

        for mouse <- mice,
            is_nil(mouse.died_at),
            mouse.mouse_id not in Map.values(matched) do
          Storage.mark_dead(mouse.mouse_id)
        end

        %{state | panes: matched}

      {:error, reason} ->
        # Without herdr there is no way to tell dead from alive, so nothing is
        # marked either way; the backstop asks again.
        warn(state, "could not list herdr panes (#{inspect(reason)})")
        state
    end
  end

  defp subscriptions(state) do
    watched = Map.keys(state.panes) ++ List.wrap(state.main_pane)

    @global_subscriptions ++
      for pane_id <- Enum.uniq(watched),
          do: %{type: "pane.agent_status_changed", pane_id: pane_id}
  end

  defp subscribe(%{socket: nil} = state), do: schedule_resubscribe(state)

  defp subscribe(state) do
    case state.herdr.subscribe(state.socket, subscriptions(state), self()) do
      {:ok, pid} ->
        %{state | subscription: pid}

      {:error, reason} ->
        warn(state, "could not subscribe to herdr (#{inspect(reason)}) — will retry")
        schedule_resubscribe(state)
    end
  end

  defp resubscribe(state) do
    state |> drop_subscription() |> subscribe()
  end

  defp schedule_resubscribe(state) do
    Process.send_after(self(), :resubscribe, state.resubscribe_ms)
    state
  end

  defp drop_subscription(%{subscription: nil} = state), do: state

  defp drop_subscription(%{subscription: pid} = state) do
    Process.unlink(pid)
    Process.exit(pid, :shutdown)
    %{state | subscription: nil}
  end

  # -- collection --------------------------------------------------------------

  defp collect_now(state), do: state |> collect_and_count() |> elem(1)

  # Collect the doorstep, then decide how delivery follows. A fresh round —
  # nothing was open and nothing is out — earns the one wait ADR-0008 allows;
  # anything else is attempted at once, and the gate decides.
  defp collect_and_count(state) do
    fresh_round? = Storage.open_count() == 0 and Storage.sent() == nil

    collected =
      state.main_checkout
      |> Doorstep.waiting()
      |> Enum.count(fn {file, entry} -> collect_entry(state, file, entry) end)

    state =
      cond do
        collected == 0 -> state
        state.round_timer != nil -> state
        fresh_round? -> start_round(state)
        true -> deliver(state)
      end

    {collected, state}
  end

  defp start_round(state) do
    %{state | round_timer: Process.send_after(self(), :round_over, state.round_wait_ms)}
  end

  defp collect_entry(state, file, entry) do
    kind = Marker.classify(entry.text)

    # A done report is open like any other and delivered in its turn
    # (ADR-0009); it is closed the moment it is sent, in send_question/3.
    status = if File.dir?(entry.worktree_root), do: "open", else: "orphaned"

    with {:ok, _} <-
           Storage.record_mouse(%{
             mouse_id: entry.mouse_id,
             path: entry.worktree_root,
             branch: entry.branch
           }),
         {:ok, question} <-
           Storage.record_question(%{
             mouse_id: entry.mouse_id,
             text: entry.text,
             kind: kind,
             status: status,
             asked_at: DateTime.truncate(entry.stamped_at, :second)
           }),
         {:ok, _} <- Storage.supersede_earlier(question),
         {:ok, _} <- Doorstep.mark_collected(file) do
      true
    else
      {:error, reason} ->
        # Left on the doorstep, uncollected: the next trigger tries again, and
        # nothing is lost in the meantime.
        warn(state, "could not collect #{Path.basename(file)} (#{inspect(reason)})")
        false
    end
  end

  # -- delivery (ADR-0008) -----------------------------------------------------

  # The gate. Every branch that holds returns the state unchanged, so calling
  # this on every trigger is safe; only a delivery changes anything.
  defp deliver(%{round_timer: timer} = state) when timer != nil, do: state

  defp deliver(%{main_pane: nil} = state) do
    if Storage.open_count() > 0 do
      warn_once(
        state,
        :no_main,
        "questions are waiting but no main session is recorded — " <>
          "run `whiska start` in the main session's pane"
      )
    else
      state
    end
  end

  defp deliver(state) do
    with nil <- Storage.sent(),
         %Question{} = question <- Storage.next_open(),
         {:go, notes} <- main_session_free?(state) do
      send_question(state, question, notes)
    else
      _ -> state
    end
  end

  defp main_session_free?(%{socket: nil} = state),
    do: warn_once(state, :no_socket, "no herdr socket known — cannot deliver")

  defp main_session_free?(state) do
    case state.herdr.pane(state.socket, state.main_pane) do
      {:ok, %{agent: "claude", agent_status: status}} when status in ["idle", "done"] ->
        {:go, []}

      {:ok, %{agent: "claude", agent_status: "unknown"}} ->
        {:go, [:status_unknown]}

      {:ok, %{agent: "claude"}} ->
        :hold

      {:ok, %{agent: nil}} ->
        warn_once(
          state,
          :main_dead,
          "the main session's pane #{state.main_pane} is not running Claude — " <>
            "questions are held; run `whiska start` where it is"
        )

      {:ok, %{agent: other}} ->
        warn_once(state, :main_dead, "the main session's pane runs #{other}, not Claude — held")

      {:error, reason} ->
        warn_once(
          state,
          :main_lookup,
          "could not ask herdr about the main pane (#{inspect(reason)})"
        )
    end
  end

  defp send_question(state, question, notes) do
    branch = branch_of(question.mouse_id)
    line = Text.compose(question, branch, Storage.open_count() - 1, notes)

    case state.herdr.prompt(state.socket, state.main_pane, line) do
      :ok ->
        {:ok, _} = Storage.mark_sent(question.id)
        settle_report(question)
        %{state | warned: MapSet.new()}

      {:error, reason} ->
        # Stays open; the next trigger tries again.
        warn(state, "could not deliver ##{question.id} (#{inspect(reason)}) — will retry")
        state
    end
  end

  # A done report is told once and never waits for an answer: closing it as
  # soon as it is sent frees ADR-0008's one slot for the next question.
  defp settle_report(%Question{kind: "done", id: id}), do: {:ok, _} = Storage.close_question(id)
  defp settle_report(_question), do: :ok

  defp branch_of(mouse_id) do
    case Storage.mouse(mouse_id) do
      %Mouse{branch: branch} when is_binary(branch) -> branch
      _ -> mouse_id
    end
  end

  # A held delivery is retried on every trigger; the reason is worth one line,
  # not one per minute. The set is cleared by the next successful delivery.
  defp warn_once(state, key, message) do
    if MapSet.member?(state.warned, key) do
      state
    else
      warn(state, message)
      %{state | warned: MapSet.put(state.warned, key)}
    end
  end

  defp warn(state, message) do
    IO.puts(:stderr, "whiska [#{Path.basename(state.main_checkout)}]: #{message}")
  end
end
