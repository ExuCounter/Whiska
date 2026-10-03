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
  to a mouse record's worktree path — at open, whenever herdr reports a new agent
  pane, and the moment a collection records a mouse no pane is known for. That is
  the first and only thing that ever fills a mouse's `pane` column (ADR-0006).

  Only the first two judge liveness: a mouse with no pane anywhere is dead
  (ADR-0026), and is marked, never deleted (ADR-0007). Matching on collection
  never marks anything dead — a dead mouse's open and sent questions cascade out
  of the queue, and the question just collected would be the casualty of a pane
  list that happened to be a moment stale.

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

  A `done` report is delivered ahead of the queue and closed the moment
  it is sent; an entry whose worktree is no longer on disk is recorded as
  orphaned rather than delivered. Whatever a mouse
  leaves supersedes its own earlier open or sent questions: it has moved past
  them, and an answer could no longer land.

  ## Delivery (ADR-0008)

  A question reaches the main session — the pane `whiska start` recorded
  (ADR-0020) — only when that pane runs Claude and reports idle, and no other
  question is already out waiting for its answer. "Already out" means a live
  mouse is waiting on it: a mouse that dies with a question sent has that
  question settled or orphaned with the rest of what it left waiting, by whether
  its branch landed (ADR-0007, ADR-0064), which
  frees the slot rather than holding it against every later question. Anything
  else joins the queue silently. The one exception is the first question of a
  fresh round, which waits `round_wait_ms` (8 s) so that the line it delivers
  carries an accurate count of what landed just behind it. Delivery is attempted
  at open, after every collection, whenever herdr reports the main pane idle,
  and on the backstop.

  A finished line is outside all of that (ADR-0008, note of 2026-10-01).
  Nothing is waiting on the person in it, so it goes ahead of whatever is
  queued, with no regard for the slot, and is closed as it is typed. The idle
  pane and the empty box still gate it — the line still lands in the person's
  terminal. A round's wait only ever gathers a count for a house that was
  quiet, so a finished line arriving while something is out starts no round and
  waits for none.

  herdr's word is taken fresh at each attempt (`pane.get`), not from the last
  event: `claude` + `idle` delivers; `working` or `blocked` holds; `claude` +
  `unknown` delivers anyway and says so in the line, since holding would be
  silence with no explanation; no agent at all is a dead pane, held with a
  warning. What is typed is one line (`Whiska.Delivery.Text`), not the message.

  A pane that passes all of that is asked one more thing (ADR-0047): whether
  the person has a draft in its prompt box, read off the screen by
  `Whiska.Delivery.Draft`. herdr's idle is the model's word, and typing into an
  occupied box would land inside what the person is writing. A draft holds the
  question — open, first in the queue, delivered on the next trigger — and a
  screen with no box on it delivers anyway, for ADR-0008's reason.

  A hold is remembered — since when, and which half of the gate held — so the
  board can say why nothing is being delivered once it has outlasted the fuse
  (ADR-0058). Only the saying is new: the gate decides exactly as it did.

  The line is typed and a hoot goes out with it (ADR-0062): one desktop
  notification per delivered question, raised in the same breath as the line
  so the two can never disagree, and never raised for a question that is only
  collected or held. It carries the house, the branch, the verb and the id —
  `Whiska.Delivery.Hoot`, which says it in the line's own words. It is a
  courtesy, not the job: a hoot that errors or raises is swallowed, and the
  question stays delivered.

  A house tells no other house anything, and nothing is ever typed into
  another repo's session (ADR-0044): the other repo's own statusline redraws
  on its `refreshInterval` timer and reads what is waiting here off disk.
  """

  use GenServer

  alias Whiska.Backstop
  alias Whiska.Cleanup
  alias Whiska.Delivery.Draft
  alias Whiska.Delivery.Hoot
  alias Whiska.Delivery.Text
  alias Whiska.Doorstep
  alias Whiska.Herdr
  alias Whiska.Layout
  alias Whiska.Pickup
  alias Whiska.Question.Marker
  alias Whiska.Schema.Mouse
  alias Whiska.Schema.Question
  alias Whiska.Storage
  alias Whiska.Watch
  alias Whiska.Watch.Snapshot

  @global_subscriptions [
    %{type: "pane.closed"},
    %{type: "pane.exited"},
    %{type: "pane.agent_detected"}
  ]

  @default_backstop_ms 60_000
  @default_resubscribe_ms 5_000
  @default_round_wait_ms 8_000
  @default_retry_ms [2_000, 5_000]
  @default_board_ms 2_000
  # How long delivery has to be holding before the board says so (ADR-0058).
  @default_hold_notice_ms 10_000
  # How long a mouse's pane has to have been quiet before a died turn is picked
  # up (ADR-0067). Two backstops, so a laptop waking cannot have a whole fleet
  # picked up on the strength of one reconnection's pane list.
  @default_settle_ms 120_000

  defstruct [
    :main_checkout,
    :socket,
    :herdr,
    :repo,
    :backstop_ms,
    :resubscribe_ms,
    :round_wait_ms,
    :retry_ms,
    :board_ms,
    :hold_notice_ms,
    :settle_ms,
    :max_gap_ms,
    held_since: nil,
    held_reason: nil,
    subscription: nil,
    board_frame: 0,
    panes: %{},
    seen: %{},
    last_sweep_at: nil,
    last_panes: :no_socket,
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
  that found nothing), `:board_ms` (how often the board is written),
  `:hold_notice_ms` (how long a hold lasts before the board says why),
  `:settle_ms` (how long a mouse's pane must have been quiet before a died turn
  is picked up), `:max_gap_ms` (how long a gap between backstops means the owl
  was not watching, so its pane memory is thrown away), `:name`.
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

  @doc "Why delivery is holding, or `nil`. For tests and the board."
  @spec held(GenServer.server()) :: Watch.held()
  def held(house), do: GenServer.call(house, :held)

  @doc "Since when delivery has been holding, or `nil`."
  @spec held_since(GenServer.server()) :: DateTime.t() | nil
  def held_since(house), do: GenServer.call(house, :held_since)

  @doc "This house's main checkout."
  @spec main_checkout(GenServer.server()) :: Path.t()
  def main_checkout(house), do: GenServer.call(house, :main_checkout)

  @doc "What the house remembers about each mouse's pane between sweeps (ADR-0067)."
  @spec seen(GenServer.server()) :: Pickup.seen()
  def seen(house), do: GenServer.call(house, :seen)

  # -- lifecycle ---------------------------------------------------------------

  defp backstop_ms(opts), do: Keyword.get(opts, :backstop_ms, @default_backstop_ms)

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
          backstop_ms: backstop_ms(opts),
          resubscribe_ms: Keyword.get(opts, :resubscribe_ms, @default_resubscribe_ms),
          round_wait_ms: Keyword.get(opts, :round_wait_ms, @default_round_wait_ms),
          retry_ms: Keyword.get(opts, :retry_ms, @default_retry_ms),
          board_ms: Keyword.get(opts, :board_ms, @default_board_ms),
          hold_notice_ms: Keyword.get(opts, :hold_notice_ms, @default_hold_notice_ms),
          settle_ms: Keyword.get(opts, :settle_ms, @default_settle_ms),
          max_gap_ms: Keyword.get(opts, :max_gap_ms, backstop_ms(opts) * 3),
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

    # Delivery is attempted at open, not only after a collection: reconciling
    # may just have freed ADR-0008's slot by marking a mouse dead that died
    # while the owl was down, and the question behind it should not wait for
    # the backstop's minute. The gate decides, and a collection that started a
    # round holds this one back anyway.
    state =
      state
      |> reconcile_panes()
      |> subscribe()
      |> collect_now()
      |> deliver()
      |> pick_up()

    Process.send_after(self(), :backstop, state.backstop_ms)
    state = write_board(state)
    Process.send_after(self(), :board, state.board_ms)
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

  @impl true
  def handle_call(:held, _from, state), do: {:reply, state.held_reason, state}

  @impl true
  def handle_call(:held_since, _from, state), do: {:reply, state.held_since, state}
  def handle_call(:sync, _from, state), do: {:reply, :ok, state}
  def handle_call(:repo, _from, state), do: {:reply, state.repo, state}
  def handle_call(:main_checkout, _from, state), do: {:reply, state.main_checkout, state}
  def handle_call(:seen, _from, state), do: {:reply, state.seen, state}

  # -- herdr events ------------------------------------------------------------

  # Every herdr event comes through here once, with its name normalised, and
  # is then dispatched by that one spelling (see "What the house watches").
  @impl true
  def handle_info({:herdr_event, name, data}, state) do
    {:noreply, herdr_event(event_name(name), data, state)}
  end

  def handle_info({:herdr_subscription_lost, reason}, state) do
    warn(state, "herdr subscription lost (#{inspect(reason)}) — will reopen it")
    # Everything the house thought it knew about a pane was learnt before the
    # drop, so every settling clock starts again rather than counting through
    # the gap (ADR-0067).
    {:noreply, schedule_resubscribe(%{state | subscription: nil, seen: %{}})}
  end

  def handle_info(:resubscribe, state), do: {:noreply, subscribe(state)}

  def handle_info(:backstop, state) do
    state = state |> refresh() |> collect_on_backstop() |> deliver() |> clean_up() |> pick_up()
    Process.send_after(self(), :backstop, state.backstop_ms)
    {:noreply, state}
  end

  def handle_info(:board, state) do
    state = write_board(%{state | last_panes: safe_list_panes(state)})
    Process.send_after(self(), :board, state.board_ms)
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

  # -- the board (ADR-0051) ----------------------------------------------------

  # `state.panes` is the match from pane to mouse and holds no status, so the
  # board keeps herdr's last full answer beside it: the one the tick asks for,
  # or the one matching panes has just fetched.
  #
  # Nothing about drawing the board may stop a house: it reads a file format
  # somebody else writes (ADR-0050), and collection and delivery must outlive
  # anything that goes wrong in it.
  #
  # The frame is counted in boards actually written rather than in seconds, so a
  # working row's ticker moves exactly when the board behind it was refreshed: a
  # house that has stopped writing leaves the dots where they were.
  defp write_board(state) do
    board = Watch.from_house(panes: state.last_panes, held: held_reason(state))

    # The recorded pane is read here rather than taken from `state.main_pane`,
    # which only moves when the house refreshes: a session that has just run
    # `whiska start` must stop being told it is not the main session on the
    # next redraw, not on the next backstop (ADR-0065).
    written =
      Snapshot.write(
        state.main_checkout,
        Watch.render(board, frame: state.board_frame),
        Storage.main_pane()
      )

    case written do
      :ok -> %{state | board_frame: state.board_frame + 1}
      {:error, _reason} -> state
    end
  rescue
    error ->
      warn(state, "could not draw the board (#{Exception.message(error)})")
      state
  end

  defp safe_list_panes(%{socket: nil}), do: :no_socket

  defp safe_list_panes(state) do
    state.herdr.list_panes(state.socket)
  rescue
    error -> {:error, Exception.message(error)}
  end

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

      %{"pane_id" => pane_id, "agent_status" => "working"} ->
        note_working(state, Map.get(state.panes, pane_id))

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

  # A turn beginning, which is the only evidence Whiska keeps that one was ever
  # asked for (ADR-0067). The sweep notices it too, a minute later at worst;
  # this is what catches a turn shorter than a backstop.
  defp note_working(state, nil), do: state

  defp note_working(state, mouse_id) do
    Storage.set_working(mouse_id, DateTime.utc_now())
    %{state | seen: Map.put(state.seen, mouse_id, %{status: "working", ready_since: nil})}
  end

  # -- panes and the subscription ----------------------------------------------

  # Re-list panes, re-read the main session, and reopen the subscription if
  # the set of panes to watch changed.
  defp refresh(state) do
    before = {Map.keys(state.panes), state.main_pane}
    state = %{reconcile_panes(state) | main_pane: Storage.main_pane()}
    after_ = {Map.keys(state.panes), state.main_pane}
    if after_ == before, do: state, else: resubscribe(state)
  end

  # Matching *and* judging liveness: every mouse herdr cannot place is marked
  # dead here (ADR-0026). That judgment belongs to this path only — see
  # `match_panes/1`.
  defp reconcile_panes(state) do
    case match_panes(state) do
      {:ok, state, mice} ->
        for mouse <- mice,
            is_nil(mouse.died_at),
            mouse.mouse_id not in Map.values(state.panes) do
          Storage.mark_dead(mouse.mouse_id)
        end

        state

      {:error, state} ->
        state
    end
  end

  # Matching alone: each mouse whose worktree holds a listed agent pane's cwd
  # gets that pane, and a mouse herdr does not list is left exactly as it was.
  #
  # Only a current record is matched (`Storage.current_mice/0`). A stale one —
  # the folder a slashed branch nests under — holds every pane of the mouse
  # inside it, and matching it both cleared its `died_at`, putting a branch that
  # no longer exists back on the board, and took the pane away from the mouse
  # actually running there, which was then marked dead on the next line.
  # A stale record is still marked dead below: it has no pane of its own.
  defp match_panes(%{socket: nil} = state) do
    warn(state, "no herdr socket known — mice cannot be matched to panes")
    {:error, state}
  end

  defp match_panes(state) do
    case state.herdr.list_panes(state.socket) do
      {:ok, panes} ->
        agent_panes = Enum.filter(panes, &(&1.agent != nil and is_binary(&1.cwd)))
        mice = Storage.all(Mouse)
        current = MapSet.new(Storage.current(mice), & &1.mouse_id)

        matched =
          for mouse <- mice,
              MapSet.member?(current, mouse.mouse_id),
              pane = Enum.find(agent_panes, &Layout.inside?(&1.cwd, mouse.path)),
              pane != nil,
              into: %{} do
            Storage.set_pane(mouse.mouse_id, pane.pane_id)
            {pane.pane_id, mouse.mouse_id}
          end

        {:ok, %{state | panes: matched, last_panes: {:ok, panes}}, mice}

      {:error, reason} ->
        # Without herdr there is no way to tell dead from alive, so nothing is
        # marked either way; the backstop asks again.
        warn(state, "could not list herdr panes (#{inspect(reason)})")
        {:error, %{state | last_panes: {:error, reason}}}
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

  # Cleanup rides the backstop rather than an event: a branch lands outside
  # Whiska entirely, so there is nothing to be told about (ADR-0061).
  defp clean_up(%{socket: nil} = state), do: state

  defp clean_up(state) do
    %{main_checkout: state.main_checkout, herdr: state.herdr, socket: state.socket}
    |> Cleanup.sweep()
    |> Enum.each(fn
      {mouse_id, :removed} ->
        warn(state, "#{label(mouse_id)} landed — worktree, pane and branch gone")

      {mouse_id, {:removed, {:branch_kept, _}}} ->
        warn(state, "#{label(mouse_id)} landed — worktree and pane gone, branch kept")

      {mouse_id, {:removed, {:unrecorded, reason}}} ->
        warn(
          state,
          "#{mouse_id}'s worktree is gone but its row is not stamped (#{inspect(reason)})"
        )

      {_mouse_id, {:left, _reason}} ->
        :ok
    end)

    state
  end

  # Picking up a turn that died, on the same backstop and for the same reason
  # cleanup rides it: a turn dies outside Whiska entirely, so there is nothing
  # to be told about (ADR-0067).
  defp pick_up(%{socket: nil} = state), do: state

  defp pick_up(state) do
    {outcomes, seen} =
      Pickup.sweep(%{
        main_checkout: state.main_checkout,
        herdr: state.herdr,
        socket: state.socket,
        panes: state.last_panes,
        main_pane: state.main_pane,
        seen: state.seen,
        last_sweep_at: state.last_sweep_at,
        max_gap_ms: state.max_gap_ms,
        settle_ms: state.settle_ms,
        now: DateTime.utc_now()
      })

    state = Enum.reduce(outcomes, state, &said/2)

    # Stamped when the sweep finished, not when it started: the gap the next
    # sweep measures is the time nobody was watching, and a slow tick is time
    # this one was.
    %{state | seen: seen, last_sweep_at: DateTime.utc_now()}
  end

  defp said({mouse_id, :picked_up}, state) do
    warn(state, "#{label(mouse_id)}'s turn ended without finishing — picked it up")
    state
  end

  defp said({mouse_id, {:left, {:refused, reason}}}, state) do
    warn(
      state,
      "#{label(mouse_id)}'s turn ended without finishing and herdr would not " <>
        "take the line (#{inspect(reason)})"
    )

    state
  end

  defp said({mouse_id, {:left, {:uncapped, reason}}}, state) do
    warn(
      state,
      "#{label(mouse_id)}'s turn ended without finishing but its pickup could not be " <>
        "recorded (#{inspect(reason)}) — nothing was typed"
    )

    state
  end

  # Nothing in this house can be picked up while it stands, and nothing moves
  # it: the owl never deletes a doorstep entry (ADR-0007). So it is said, once.
  defp said({_mouse_id, {:left, :doorstep_unreadable}}, state) do
    warn_once(
      state,
      :doorstep_unreadable,
      "an entry on the doorstep will not parse — no turn in this house can be picked " <>
        "up until it is moved out of #{Doorstep.path(state.main_checkout)}"
    )
  end

  defp said({_mouse_id, {:left, _reason}}, state), do: state

  defp label(mouse_id) do
    case Storage.mouse(mouse_id) do
      %Mouse{branch: branch} when is_binary(branch) -> branch
      _ -> mouse_id
    end
  end

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

    mice =
      state.main_checkout
      |> Doorstep.waiting()
      |> Enum.filter(fn {file, entry} -> collect_entry(state, file, entry) end)
      |> Enum.map(fn {_file, entry} -> entry.mouse_id end)

    collected = length(mice)
    state = match_new_mice(state, mice)

    state =
      cond do
        collected == 0 -> state
        state.round_timer != nil -> stop_retries(state)
        fresh_round? -> state |> stop_retries() |> start_round()
        true -> state |> stop_retries() |> deliver()
      end

    {collected, state}
  end

  # A collection is the first the house hears of a mouse that has never been
  # matched to a pane — `collect_entry/3` records the mouse from the entry
  # itself. Left to `refresh/1`'s own triggers the pane column stayed nil until
  # the backstop's minute was up, and in that minute `whiska waiting` said "no
  # pane" and `whiska reply` refused (ADR-0043's note of 2026-09-28). So an
  # unmatched mouse is matched here and now: one `list_panes` call, and only
  # when a collection named a mouse no pane is known for. A mouse already in
  # `state.panes` asks herdr nothing.
  defp match_new_mice(state, []), do: state

  defp match_new_mice(state, mouse_ids) do
    known = Map.values(state.panes)
    if Enum.all?(mouse_ids, &(&1 in known)), do: state, else: rematch(state)
  end

  # Matching only, never `refresh/1`: a mouse herdr does not list must not be
  # marked dead here. Marking dead cascades its open questions to `orphaned`
  # (ADR-0026), and the question just collected is precisely the one that would
  # be lost to a stale pane list. Liveness stays the backstop's judgment, by
  # which time the mouse has had its minute to appear.
  defp rematch(state) do
    before = Map.keys(state.panes)
    state = match_panes_only(state)
    if Map.keys(state.panes) == before, do: state, else: resubscribe(state)
  end

  defp match_panes_only(state) do
    case match_panes(state) do
      {:ok, state, _mice} -> state
      {:error, state} -> state
    end
  end

  # A done report is open like any other and delivered in its turn (ADR-0009);
  # it is closed the moment it is sent, in send_question/3. An entry whose
  # worktree has already gone has nowhere to reply to, so it arrives where the
  # rest of that mouse's questions went — settled if its branch landed,
  # orphaned if it did not (ADR-0064). The mouse is recorded first, so the
  # question of a mouse nobody had heard of is asked of a row that exists.
  defp arriving(entry) do
    if File.dir?(entry.worktree_root),
      do: "open",
      else: Storage.terminal_status(entry.mouse_id)
  end

  defp start_round(state) do
    %{state | round_timer: Process.send_after(self(), :round_over, state.round_wait_ms)}
  end

  defp collect_entry(state, file, entry) do
    kind = Marker.classify(entry.text)

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
             status: arriving(entry),
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
  # The sweep runs whatever the gate then decides, a round's wait included: a
  # question nothing can answer must not sit in the count that wait is
  # gathering (ADR-0057).
  defp deliver(state) do
    release_unanswerable(state)

    if state.round_timer, do: state, else: to_main_session(state)
  end

  defp to_main_session(%{main_pane: nil} = state) do
    if Storage.open_count() > 0 do
      state
      |> warn_once(
        :no_main,
        "questions are waiting but no main session is recorded — " <>
          "run `whiska start` in the main session's pane"
      )
      |> hold(:unreachable)
    else
      release_hold(state)
    end
  end

  defp to_main_session(state) do
    case next_to_deliver() do
      nil ->
        release_hold(state)

      %Question{} = question ->
        case main_session_free?(state) do
          {:go, notes, state} -> send_question(state, question, notes)
          {:hold, reason, state} -> hold(state, reason)
        end
    end
  end

  # How long delivery has been holding, and why. The gate is unchanged
  # (ADR-0008, ADR-0047); this only remembers what it decided, so the board can
  # say it (ADR-0058). A hold whose reason changes — mid-turn, then a draft in
  # the box — is one hold that has not let go, so the clock keeps running.
  defp hold(%{held_since: %DateTime{}} = state, reason), do: %{state | held_reason: reason}
  defp hold(state, reason), do: %{state | held_since: now(), held_reason: reason}

  defp release_hold(state), do: %{state | held_since: nil, held_reason: nil}

  # Said only once the hold has outlasted the fuse, and only while something is
  # actually queued behind it.
  defp held_reason(state) do
    with %DateTime{} = since <- state.held_since,
         true <- DateTime.diff(now(), since, :millisecond) >= state.hold_notice_ms,
         true <- Storage.open_count() > 0 do
      state.held_reason
    else
      _ -> nil
    end
  end

  defp now, do: DateTime.utc_now()

  # Nothing that cannot be answered may hold the one slot (ADR-0057). A mouse
  # dies and is marked dead; a doorstep entry it left behind is collected after
  # that, arrives `open` and is delivered, and then holds the slot with nothing
  # alive behind it. Judging the queue here, on every trigger, is what makes
  # the rule hold whatever order those two happen in.
  defp release_unanswerable(state) do
    case Storage.release_unanswerable() do
      [] ->
        :ok

      released ->
        warn(
          state,
          "released #{length(released)} question(s) nothing can answer any more: " <>
            Enum.map_join(released, ", ", &"##{&1.id}")
        )
    end
  end

  # What goes next, if the main session will have it. A finished line is not a
  # question — nothing is waiting on the person in it — so it neither waits for
  # the one slot nor holds it: it goes first, and is closed as it is sent. A
  # real question goes only when the slot is free, exactly as before.
  defp next_to_deliver do
    case Storage.next_done() do
      %Question{} = report -> report
      nil -> if Storage.sent() == nil, do: Storage.next_open()
    end
  end

  defp main_session_free?(%{socket: nil} = state) do
    state
    |> warn_once(:no_socket, "no herdr socket known — cannot deliver")
    |> then(&{:hold, :unreachable, &1})
  end

  defp main_session_free?(state) do
    case state.herdr.pane(state.socket, state.main_pane) do
      {:ok, %{agent: "claude", agent_status: status}} when status in ["idle", "done"] ->
        not_typing(state, [])

      {:ok, %{agent: "claude", agent_status: "unknown"}} ->
        not_typing(state, [:status_unknown])

      {:ok, %{agent: "claude"}} ->
        {:hold, :mid_turn, state}

      {:ok, %{agent: nil}} ->
        state
        |> warn_once(
          :main_dead,
          "the main session's pane #{state.main_pane} is not running Claude — " <>
            "questions are held; run `whiska start` where it is"
        )
        |> then(&{:hold, :unreachable, &1})

      {:ok, %{agent: other}} ->
        state
        |> warn_once(:main_dead, "the main session's pane runs #{other}, not Claude — held")
        |> then(&{:hold, :unreachable, &1})

      {:error, reason} ->
        state
        |> warn_once(
          :main_lookup,
          "could not ask herdr about the main pane (#{inspect(reason)})"
        )
        |> then(&{:hold, :unreachable, &1})
    end
  end

  # The second half of the gate (ADR-0047). herdr's idle is the model's word,
  # not the person's: a half-typed prompt sits in the box while the pane is
  # every bit as idle, and a line typed into that box lands inside the draft or
  # submits it. The screen is the only place that shows it, so the screen is
  # read. An unreadable one is ADR-0008's unavailable signal — deliver anyway.
  defp not_typing(state, notes) do
    case state.herdr.read_screen(state.socket, state.main_pane) do
      {:ok, screen} ->
        if Draft.read(screen) == :typing,
          do: {:hold, :typing, state},
          else: {:go, notes, state}

      {:error, _reason} ->
        {:go, notes, state}
    end
  end

  defp send_question(state, question, notes) do
    branch = branch_of(question.mouse_id)
    more_open = Storage.open_count() - 1
    line = Text.compose(question, branch, more_open, notes)

    case state.herdr.prompt(state.socket, state.main_pane, line) do
      :ok ->
        {:ok, _} = Storage.mark_sent(question.id)
        settle_report(question)
        hoot(state, question, branch, more_open)
        %{release_hold(state) | warned: MapSet.new()}

      {:error, reason} ->
        # Stays open, and stays held: a delivery herdr keeps refusing is the
        # silence ADR-0058 exists for, not a clean slate.
        state
        |> warn_once(
          :prompt_failed,
          "could not deliver ##{question.id} (#{inspect(reason)}) — will retry"
        )
        |> hold(:unreachable)
    end
  end

  # The hoot (ADR-0062), raised from inside the same branch that typed the
  # line, so the two can never disagree about what reached the person.
  #
  # Delivery is the job and the hoot is a courtesy, so it is wrapped twice
  # over: the question is already recorded sent before this runs, and anything
  # herdr does here — an error, a timeout, a raise because the socket went away
  # between the two calls — is swallowed rather than allowed to fail the
  # delivery or take the house down. herdr's answer says whether it drew
  # anything, and that is dropped too: a person who has turned popups off has
  # not asked to hear about it once per delivery. `whiska doctor` asks the same
  # question once, where an answer is what the person came for.
  defp hoot(state, question, branch, more_open) do
    notification = Hoot.compose(question, Path.basename(state.main_checkout), branch, more_open)
    state.herdr.notify(state.socket, notification)
  catch
    _kind, _reason -> :ok
  end

  # A done report is told once and never waits for an answer: closing it as
  # soon as it is sent means it never takes ADR-0008's one slot at all.
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
