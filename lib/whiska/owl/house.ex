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

  Two facts about the stream, both checked against herdr 0.8.2 on 2026-09-28
  (the live socket and `herdr api schema`), because getting either wrong made
  every collection and delivery wait for the backstop:

  - **The event name has two spellings.** A per-pane subscription event is
    streamed under its subscription type, `pane.agent_status_changed`; a global
    one under its event type, `pane_closed`, `pane_exited`,
    `pane_agent_detected`. The house folds the dot form into the underscore
    form on arrival and matches only the latter.
  - **`done` is what a mouse reports.** herdr's statuses are `idle`, `working`,
    `blocked`, `done` and `unknown`. In herdr's own words, `idle` means the
    agent is ready for input and its tab has been seen in the focused UI, and
    `done` is the same underlying state after work finished in a tab the person
    had not looked at. A mouse works in a background worktree, so the end of
    its turn arrives as `working` → `done`; the main pane, focused, reports
    `idle`. Both mean "ready for input" and both trigger. `blocked` is an
    approval or question dialog; `unknown` is an agent herdr cannot classify.

  ## Collection (ADR-0036)

  Three triggers, only one of them a timer: a mouse pane reporting `done` or
  `idle`, opening the house, and a slow backstop. Each one reads the doorstep,
  records every entry as a question — classified by its marker alone
  (ADR-0009) — and marks the entry collected.

  The idle trigger races Whiska's own `Stop` hook — Claude Code runs the two in
  no fixed order — so herdr's idle event can arrive before the entry is on the
  doorstep. When an idle collection finds nothing, the house looks again after
  each delay in `retry_ms` (2 s, then 5 s) and stops as soon as any collection
  finds something. One idle event's retries are never stacked on another's; the
  backstop stays the last resort — and says so: when the backstop collects
  anything, the house warns and marks it (`Whiska.Backstop`), because everything
  it picks up is something the idle trigger should have brought a minute
  earlier. Collecting at open does not count; that is the designed "what landed
  while the owl was down" path.

  A `done` report is delivered like any other and closed the moment
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

  ## The nudge (ADR-0041)

  After each collection the house tells `Whiska.Owl.Nudge` whether it has
  something open that waits on the person — an open or sent question other
  than a `done` report. In return, Nudge may ask this house to type a nudge
  line about *other* houses into its main session (`nudge/2`). The same gate
  decides: the pane must be free and no question of this house's own may be
  out — but a nudge is never recorded, never holds the slot, and is never
  retried if the gate holds. Houses never call each other.
  """

  use GenServer

  alias Whiska.Backstop
  alias Whiska.Delivery.Text
  alias Whiska.Doorstep
  alias Whiska.Herdr
  alias Whiska.Layout
  alias Whiska.Owl.Nudge
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
  @default_retry_ms [2_000, 5_000]

  defstruct [
    :main_checkout,
    :socket,
    :herdr,
    :repo,
    :backstop_ms,
    :resubscribe_ms,
    :round_wait_ms,
    :retry_ms,
    subscription: nil,
    panes: %{},
    main_pane: nil,
    round_timer: nil,
    retry_timer: nil,
    retries_left: [],
    backstop_collections: 0,
    last_backstop_at: nil,
    warned: MapSet.new()
  ]

  # -- API ---------------------------------------------------------------------

  @doc """
  Open a house.

  Options: `:main_checkout` (required), `:herdr_socket` (defaults to
  `HERDR_SOCKET_PATH`), `:backstop_ms`, `:resubscribe_ms`, `:round_wait_ms`,
  `:retry_ms` (the delays, in order, of the re-collections after an idle event
  that found nothing), `:name`.
  """
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @doc "Collect this house's doorstep now. Returns how many entries were collected."
  @spec collect(GenServer.server()) :: {:ok, non_neg_integer()}
  def collect(house), do: GenServer.call(house, :collect)

  @doc """
  Type a nudge line into this house's main session, if its gate allows it now.
  Returns the pane it was typed into, or `:held` — and a held nudge is dropped,
  not queued (ADR-0041).
  """
  @spec nudge(GenServer.server(), String.t()) :: {:ok, String.t()} | :held
  def nudge(house, line), do: GenServer.call(house, {:nudge, line})

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
          retry_ms: Keyword.get(opts, :retry_ms, @default_retry_ms),
          main_pane: Storage.main_pane()
        }

        {:ok, state, {:continue, :open}}

      {:error, reason} ->
        {:stop, {:cannot_open_house, reason}}
    end
  end

  @impl true
  def handle_continue(:open, state) do
    # The mark counts backstop collections since *this* owl opened this house,
    # so an older owl's does not follow it around (ADR-0036).
    Backstop.clear(state.main_checkout)

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

  def handle_call({:nudge, line}, _from, state) do
    {reply, state} = send_nudge(state, line)
    {:reply, reply, state}
  end

  def handle_call(:reconcile, _from, state), do: {:reply, :ok, refresh(state)}
  def handle_call(:sync, _from, state), do: {:reply, :ok, state}
  def handle_call(:repo, _from, state), do: {:reply, state.repo, state}
  def handle_call(:main_checkout, _from, state), do: {:reply, state.main_checkout, state}

  # -- herdr events ------------------------------------------------------------

  # Every herdr event comes through here once, with its name normalised, and
  # is then dispatched by that one spelling (see "What the house watches").
  @impl true
  def handle_info({:herdr_event, name, data}, state) do
    {:noreply, herdr_event(event_name(name), data, state)}
  end

  def handle_info({:herdr_subscription_lost, reason}, state) do
    warn(state, "herdr subscription lost (#{inspect(reason)}) — will reopen it")
    {:noreply, schedule_resubscribe(%{state | subscription: nil})}
  end

  def handle_info(:resubscribe, state), do: {:noreply, subscribe(state)}

  def handle_info(:backstop, state) do
    state = state |> refresh() |> collect_on_backstop() |> deliver()
    Process.send_after(self(), :backstop, state.backstop_ms)
    {:noreply, state}
  end

  def handle_info(:round_over, state) do
    {:noreply, deliver(%{state | round_timer: nil})}
  end

  def handle_info(:retry_collect, state) do
    state = %{state | retry_timer: nil}

    case collect_and_count(state) do
      {0, state} -> {:noreply, schedule_retry(state)}
      {_found, state} -> {:noreply, state}
    end
  end

  # The subscription process ending normally has already been announced by its
  # own message. Anything else linked to us dying is a reason to stop.
  def handle_info({:EXIT, pid, _reason}, %{subscription: pid} = state), do: {:noreply, state}
  def handle_info({:EXIT, _pid, :normal}, state), do: {:noreply, state}
  def handle_info({:EXIT, _pid, :shutdown}, state), do: {:noreply, state}

  def handle_info({:EXIT, pid, reason}, %{repo: pid} = state),
    do: {:stop, {:repo_down, reason}, state}

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  # -- herdr events, by name ---------------------------------------------------

  # herdr 0.8.2 streams a per-pane subscription event under its subscription
  # type (`pane.agent_status_changed`) but a global one under its event type
  # (`pane_closed`): the same event, two spellings, depending on how it was
  # subscribed. The house speaks the underscore form, so the dot form is folded
  # into it here. This is done in the house rather than in `Whiska.Herdr.Socket`
  # because the house is what the `Whiska.Herdr` fake feeds directly (ADR-0031):
  # a normalisation in the socket client would be invisible to every test and to
  # any other implementation of the behaviour, and the contract stays "herdr's
  # own name, verbatim".
  defp event_name(name), do: String.replace(name, ".", "_")

  defp herdr_event("pane_agent_status_changed", data, state) do
    case data do
      %{"pane_id" => pane_id, "agent_status" => status}
      when status in ["idle", "done"] and pane_id == state.main_pane and pane_id != nil ->
        # The person is free: the next question can go, unless a fresh round is
        # still gathering its count.
        deliver(state)

      %{"pane_id" => pane_id, "agent_status" => status} when status in ["idle", "done"] ->
        if Map.has_key?(state.panes, pane_id),
          do: collect_after_idle(state),
          else: state

      _ ->
        state
    end
  end

  defp herdr_event(gone, %{"pane_id" => pane_id}, state)
       when gone in ["pane_closed", "pane_exited"] do
    case Map.pop(state.panes, pane_id) do
      {nil, _} ->
        state

      {mouse_id, panes} ->
        Storage.mark_dead(mouse_id)
        resubscribe(%{state | panes: panes})
    end
  end

  defp herdr_event("pane_agent_detected", _data, state), do: refresh(state)
  defp herdr_event(_other, _data, state), do: state

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

  # The backstop is the last resort, and anything it finds is something the idle
  # trigger should have brought a minute ago. Collecting at open is a different
  # thing — that is the designed "what landed while the owl was down" path — and
  # so are the idle trigger's own 2 s and 5 s retries; neither is counted here.
  # This announcing itself is what stops a dead trigger hiding behind a working
  # backstop, as it did for weeks (ADR-0036, note of 2026-09-28).
  defp collect_on_backstop(state) do
    case collect_and_count(state) do
      {0, state} -> state
      {found, state} -> note_backstop(state, found)
    end
  end

  defp note_backstop(state, found) do
    at = DateTime.utc_now()
    count = state.backstop_collections + found

    warn(
      state,
      "the backstop collected #{entries(found)} the idle trigger missed " <>
        "(#{entries(count)} since this house opened) — run `whiska doctor`"
    )

    Backstop.record(state.main_checkout, count, at)
    %{state | backstop_collections: count, last_backstop_at: at}
  end

  defp entries(1), do: "1 entry"
  defp entries(n), do: "#{n} entries"

  # The idle trigger. An empty doorstep here usually means Whiska's Stop hook
  # has not finished writing yet, so look again shortly — unless retries from
  # an earlier idle event are already pending, in which case they will.
  defp collect_after_idle(state) do
    case collect_and_count(state) do
      {0, %{retry_timer: nil} = state} -> schedule_retry(%{state | retries_left: state.retry_ms})
      {_found, state} -> state
    end
  end

  defp schedule_retry(%{retries_left: []} = state), do: state

  defp schedule_retry(%{retries_left: [delay | rest]} = state) do
    %{state | retry_timer: Process.send_after(self(), :retry_collect, delay), retries_left: rest}
  end

  # Anything found, by any trigger, is what the retries were waiting for.
  defp stop_retries(%{retry_timer: nil} = state), do: %{state | retries_left: []}

  defp stop_retries(%{retry_timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | retry_timer: nil, retries_left: []}
  end

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
        state.round_timer != nil -> stop_retries(state)
        fresh_round? -> state |> stop_retries() |> start_round()
        true -> state |> stop_retries() |> deliver()
      end

    Nudge.report(state.main_checkout, waiting_on_person?())
    {collected, state}
  end

  # What the nudge is about: a question waiting on the person, here. A `done`
  # report is told and closed on its own; nothing about it can be acted on
  # from elsewhere (ADR-0041).
  defp waiting_on_person?, do: Enum.any?(Storage.questions(), &(&1.kind != "done"))

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

  # The nudge runs the same gate as a question — free pane, no question of this
  # house's own out — and then leaves no trace: nothing recorded, nothing to
  # close, no retry.
  defp send_nudge(%{main_pane: nil} = state, _line), do: {:held, state}

  defp send_nudge(state, line) do
    with nil <- Storage.sent(),
         {:go, _notes} <- main_session_free?(state),
         :ok <- state.herdr.prompt(state.socket, state.main_pane, line) do
      {{:ok, state.main_pane}, state}
    else
      %Question{} ->
        {:held, state}

      :hold ->
        {:held, state}

      %__MODULE__{} = state ->
        {:held, state}

      {:error, reason} ->
        warn(state, "could not type a nudge (#{inspect(reason)}) — dropped")
        {:held, state}
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
