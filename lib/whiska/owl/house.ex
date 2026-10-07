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

  A `done` report waits for the slot, goes ahead of the queue once it is free,
  and is closed the moment it is sent; an entry whose worktree is no longer on disk is recorded as
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

  A finished line waits for the slot like any question, so it never lands over
  one the person is reading, but it never holds it (ADR-0008, note of
  2026-10-06): once the slot is free it goes ahead of whatever is queued, and
  is closed as it is typed. A round's wait only ever gathers a count for a
  house that was quiet, so a finished line arriving while something is out
  starts no round; it waits for the slot and nothing else.

  herdr's word is taken fresh at each attempt (`pane.get`), not from the last
  event: `claude` + `idle` delivers; `working` or `blocked` holds; `claude` +
  `unknown` delivers anyway and says so in the line, since holding would be
  silence with no explanation; no agent at all is a dead pane, held with a
  warning. What is typed is one line (`Whiska.Delivery.Text`), not the message.

  A pane that passes all of that is asked one more thing (ADR-0047): where the
  owl's line would land, read off the screen by `Whiska.Delivery.Draft`. herdr's
  idle is the model's word, and typing into an occupied box would land inside
  what the person is writing. A draft holds the question — open, first in the
  queue, delivered on the next trigger. A screen with no box on it at all holds
  it too (ADR-0068): there is nowhere for the line to land, and a dialog waiting
  on the person is one of the ways to get there. A box whose contents Whiska
  cannot read is the unreadable signal ADR-0008 rules on, and delivers anyway.

  A hold is remembered — since when, and which half of the gate held — so the
  main checkout's sidebar line can say why nothing is being delivered once it
  has outlasted the fuse (ADR-0058). Only the saying is new: the gate decides exactly as it did.

  The line is typed and a hoot goes out with it (ADR-0062): one desktop
  notification per delivered question, raised in the same breath as the line
  so the two can never disagree, and never raised for a question that is only
  collected or held. It carries the house, the branch, the verb and the id —
  `Whiska.Delivery.Hoot`, which says it in the line's own words. It is a
  courtesy, not the job: a hoot that errors or raises is swallowed, and the
  question stays delivered. When herdr says it will not draw the hoot because
  its popups are off or nobody is attached, the same hoot is raised on the
  desktop instead (ADR-0071).

  A house tells no other house anything, and nothing is ever typed into
  another repo's session (ADR-0044): herdr's tab bar redraws on its own timer
  and reads what is waiting here off disk.

  The house keeps a line under each of its mice's herdr workspaces, and one
  under its main checkout's (`Whiska.Sidebar`,
  ADR-next-a-mouses-state-is-a-line-in-herdrs-sidebar). It reads back what
  herdr is showing every time it asks herdr for its panes and sends whatever
  differs — which is how a line lost to a herdr restart comes back — and sends
  every line again before its TTL runs out, so a line nobody is keeping current
  expires. The mice are re-sorted only when the set of them that needs the
  person changes, so rows do not move under the cursor otherwise.
  """

  use GenServer

  alias Whiska.Backstop
  alias Whiska.Cleanup
  alias Whiska.Delivery.Draft
  alias Whiska.Delivery.Hoot
  alias Whiska.Delivery.Mode
  alias Whiska.Delivery.Text
  alias Whiska.Doorbell
  alias Whiska.Doorstep
  alias Whiska.Herdr
  alias Whiska.Layout
  alias Whiska.Pickup
  alias Whiska.Question.Marker
  alias Whiska.Schema.Mouse
  alias Whiska.Schema.Question
  alias Whiska.Storage
  alias Whiska.Sidebar
  alias Whiska.Watch

  @global_subscriptions [
    %{type: "pane.closed"},
    %{type: "pane.exited"},
    %{type: "pane.agent_detected"},
    %{type: "workspace.closed"}
  ]

  @default_backstop_ms 60_000
  @default_resubscribe_ms 5_000
  @default_round_wait_ms 8_000
  @default_retry_ms [2_000, 5_000]
  # The sidebar is written every second so a working mouse's spinner turns, but
  # the board under it is built afresh only every two: what herdr says moves no
  # faster than that, and asking it, the database and every transcript is what
  # a build costs.
  @default_board_ms 1_000
  @default_panes_ms 2_000
  # A sidebar line lives this long unless it is sent again, and is sent again
  # this long after it last was: a dead owl's lines are gone within the TTL,
  # and a live owl gets two tries before one lapses.
  @default_sidebar_ttl_ms 30_000
  @default_sidebar_refresh_ms 20_000
  # How long delivery has to be holding before the sidebar says so (ADR-0058).
  @default_hold_notice_ms 10_000
  # How long a mouse's pane has to have been quiet before a died turn is picked
  # up (ADR-0067). Two backstops, so a laptop waking cannot have a whole fleet
  # picked up on the strength of one reconnection's pane list.
  @default_settle_ms 120_000
  # How long after a doorbell, unanswered by a take, the owl rings it again
  # (ADR-0080). Checked on the backstop, so the
  # real spacing is this to this plus one backstop.
  @default_ring_ms 90_000

  defstruct [
    :main_checkout,
    :socket,
    :herdr,
    :desktop,
    :repo,
    :backstop_ms,
    :resubscribe_ms,
    :round_wait_ms,
    :retry_ms,
    :board_ms,
    :panes_ms,
    :sidebar_ttl_ms,
    :sidebar_refresh_ms,
    :hold_notice_ms,
    :settle_ms,
    :max_gap_ms,
    :ring_ms,
    :away_path,
    last_mode: nil,
    held_since: nil,
    held_reason: nil,
    subscription: nil,
    sidebar_frame: 0,
    workspaces: nil,
    shown: %{},
    sent_at: %{},
    needing: nil,
    panes: %{},
    seen: %{},
    last_sweep_at: nil,
    last_panes: :no_socket,
    panes_asked_at: nil,
    last_board: nil,
    board_built_at: nil,
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
  that found nothing), `:board_ms` (how often the sidebar lines are written),
  `:panes_ms` (how often the board is built afresh, herdr's panes and
  workspaces read with it), `:sidebar_ttl_ms` (how long a sidebar line lives
  unless it is sent again), `:sidebar_refresh_ms` (how long after a send it is
  sent again),
  `:hold_notice_ms` (how long a hold lasts before the sidebar says why),
  `:settle_ms` (how long a mouse's pane must have been quiet before a died turn
  is picked up), `:max_gap_ms` (how long a gap between backstops means the owl
  was not watching, so its pane memory is thrown away), `:ring_ms` (how long
  after a doorbell an answer not taken is rung again), `:desktop` (where a hoot
  herdr will not show is raised, `Whiska.Desktop.impl/0` by default),
  `:away_path` (the file that says the person is away, the real one by
  default), `:name`.
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

  @doc "Why delivery is holding, or `nil`. For tests and the sidebar."
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
          desktop: Keyword.get(opts, :desktop, Whiska.Desktop.impl()),
          repo: repo,
          backstop_ms: backstop_ms(opts),
          resubscribe_ms: Keyword.get(opts, :resubscribe_ms, @default_resubscribe_ms),
          round_wait_ms: Keyword.get(opts, :round_wait_ms, @default_round_wait_ms),
          retry_ms: Keyword.get(opts, :retry_ms, @default_retry_ms),
          board_ms: Keyword.get(opts, :board_ms, @default_board_ms),
          panes_ms: Keyword.get(opts, :panes_ms, @default_panes_ms),
          sidebar_ttl_ms: Keyword.get(opts, :sidebar_ttl_ms, @default_sidebar_ttl_ms),
          sidebar_refresh_ms: Keyword.get(opts, :sidebar_refresh_ms, @default_sidebar_refresh_ms),
          hold_notice_ms: Keyword.get(opts, :hold_notice_ms, @default_hold_notice_ms),
          settle_ms: Keyword.get(opts, :settle_ms, @default_settle_ms),
          max_gap_ms: Keyword.get(opts, :max_gap_ms, backstop_ms(opts) * 3),
          ring_ms: Keyword.get(opts, :ring_ms, @default_ring_ms),
          away_path: Keyword.get_lazy(opts, :away_path, &Mode.away_path/0),
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

    # A statusline script an older `whiska init` committed prints whatever it
    # finds here; with nothing here it prints only the person's own line.
    File.rm_rf(Path.join(Whiska.OpenHouses.home(), "board"))

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
    state =
      state
      |> refresh()
      |> collect_on_backstop()
      |> deliver()
      |> clean_up()
      |> ring()
      |> pick_up()

    Process.send_after(self(), :backstop, state.backstop_ms)
    {:noreply, state}
  end

  def handle_info(:board, state) do
    state = write_board(state)
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

  # -- the sidebar (ADR-next-a-mouses-state-is-a-line-in-herdrs-sidebar) -------

  # `state.panes` is the match from pane to mouse and holds no status, so the
  # board keeps herdr's last full answer beside it: the one the tick asks for,
  # or the one matching panes has just fetched.
  #
  # Nothing about the sidebar may stop a house: it reads a file format somebody
  # else writes (ADR-0050) and talks to a herdr that may not know the calls, and
  # collection and delivery must outlive anything that goes wrong in it.
  defp write_board(state) do
    {board, fresh?, state} = board(state)
    state = if fresh?, do: read_workspaces(state), else: state

    case state.workspaces do
      nil ->
        %{state | last_board: board}

      workspaces ->
        state
        |> show(board, workspaces)
        |> Map.merge(%{last_board: board, sidebar_frame: state.sidebar_frame + 1})
    end
  rescue
    error ->
      warn_once(state, :sidebar, "could not draw the sidebar (#{Exception.message(error)})")
  end

  # The board is built afresh — herdr, the database, every mouse's transcript —
  # once every `panes_ms`. A write in between reuses it: what it says changes no
  # faster than herdr's answer does, and the sidebar spells its ages in minutes.
  # Why delivery is holding is the house's own state and costs nothing, so it is
  # always current.
  defp board(state) do
    built_at = state.board_built_at

    if state.last_board && built_at &&
         System.monotonic_time(:millisecond) - built_at < state.panes_ms do
      board = %{state.last_board | held: held_reason(state, state.last_mode || mode(state))}
      {board, false, state}
    else
      state = state |> refresh_board_panes() |> notice_mode()
      mode = state.last_mode

      board =
        Watch.from_house(panes: state.last_panes, held: held_reason(state, mode), mode: mode)

      {board, true, %{state | board_built_at: System.monotonic_time(:millisecond)}}
    end
  end

  # What herdr is showing is read back with the panes, every `panes_ms`, so a
  # line herdr lost — its server restarted — is noticed and sent again.
  defp read_workspaces(%{socket: nil} = state), do: state

  defp read_workspaces(state) do
    case state.herdr.workspaces(state.socket) do
      {:ok, workspaces} ->
        shown = Map.new(workspaces, &{&1.workspace_id, Map.take(&1.tokens, Sidebar.keys())})
        %{state | workspaces: workspaces, shown: shown}

      {:error, reason} ->
        warn_once(state, :workspaces, "could not list herdr workspaces (#{inspect(reason)})")
    end
  end

  defp show(state, board, workspaces) do
    lines = Sidebar.mice(board, now: DateTime.utc_now(), frame: state.sidebar_frame)
    main = main_workspace(workspaces, state)
    placed = Sidebar.place(board, workspaces, main)

    no_workspace =
      for row <- board.rows,
          not Map.has_key?(placed, row.mouse_id),
          into: MapSet.new(),
          do: row.mouse_id

    house =
      Sidebar.house(board, main_pane?: Storage.main_pane() != nil, no_workspace: no_workspace)

    wanted =
      lines
      |> Enum.filter(&Map.has_key?(placed, &1.mouse_id))
      |> Map.new(&{placed[&1.mouse_id], &1.tokens})
      |> put_main(main, house)

    state
    |> send_lines(wanted, ours(workspaces, wanted, state))
    |> sort(lines, placed, workspaces)
  end

  defp main_workspace(workspaces, state) do
    main = Path.expand(state.main_checkout)

    Enum.find_value(workspaces, fn ws ->
      if is_binary(ws.path) and Path.expand(ws.path) == main and ws.linked? != true,
        do: ws.workspace_id
    end) || main_pane_workspace(state, workspaces)
  end

  # Only a workspace opened on no checkout, as for a mouse (`Whiska.Sidebar.place/2`):
  # one opened on a checkout belongs to that checkout's own house.
  defp main_pane_workspace(%{last_panes: {:ok, panes}}, workspaces) do
    main_pane = Storage.main_pane()
    ws = Enum.find_value(panes, &(&1.pane_id == main_pane && Map.get(&1, :workspace_id)))

    if Enum.any?(workspaces, &(&1.workspace_id == ws and is_nil(&1.path))), do: ws
  end

  defp main_pane_workspace(_state, _workspaces), do: nil

  defp put_main(wanted, nil, _house), do: wanted
  defp put_main(wanted, ws, house), do: Map.put(wanted, ws, house)

  # Every workspace this house speaks for: the ones it has a line for, the ones
  # it has sent a line to before, and any open on a worktree of this repo — so a
  # line left on a mouse that has since stopped is cleared rather than left to
  # expire. Another house's workspaces are none of these.
  defp ours(workspaces, wanted, state) do
    worktrees = Path.join(Path.expand(state.main_checkout), "worktrees")

    under =
      for ws <- workspaces,
          is_binary(ws.path),
          Layout.inside?(Path.expand(ws.path), worktrees),
          do: ws.workspace_id

    existing = MapSet.new(workspaces, & &1.workspace_id)

    (Map.keys(wanted) ++ Map.keys(state.sent_at) ++ under)
    |> Enum.uniq()
    |> Enum.filter(&MapSet.member?(existing, &1))
  end

  # A line is sent when what herdr holds differs from it, and again before its
  # TTL runs out. Every key is named on each send, a missing one as `nil`, so a
  # line that got shorter clears what it no longer says.
  #
  # The first send herdr refuses or times out on ends the tick's sending: a
  # herdr that takes connections and never answers would otherwise hold the
  # house for one reply timeout per line.
  defp send_lines(state, wanted, ours) do
    now = System.monotonic_time(:millisecond)

    Enum.reduce_while(ours, state, fn ws, state ->
      want = Map.get(wanted, ws, %{})
      held = Map.get(state.shown, ws, %{})

      cond do
        want != held -> send_line(state, ws, want, now)
        want != %{} and due?(state, ws, now) -> send_line(state, ws, want, now)
        true -> {:cont, state}
      end
    end)
  end

  defp due?(state, ws, now),
    do:
      now - Map.get(state.sent_at, ws, now - state.sidebar_refresh_ms) >= state.sidebar_refresh_ms

  defp send_line(state, ws, want, now) do
    tokens = Map.new(Sidebar.keys(), &{&1, Map.get(want, &1)})

    case state.herdr.report_metadata(state.socket, ws, tokens, state.sidebar_ttl_ms) do
      :ok ->
        {:cont,
         %{
           state
           | shown: Map.put(state.shown, ws, want),
             sent_at: sent(state.sent_at, ws, want, now)
         }}

      {:error, reason} ->
        {:halt,
         warn_once(
           state,
           :report_metadata,
           "herdr would not take a sidebar line (#{inspect(reason)})"
         )}
    end
  end

  # A workspace whose line has been cleared is forgotten, so the house stops
  # speaking for one it no longer has a line on.
  defp sent(sent_at, ws, want, _now) when want == %{}, do: Map.delete(sent_at, ws)
  defp sent(sent_at, ws, _want, now), do: Map.put(sent_at, ws, now)

  # The mice re-sort only when one starts or stops needing the person, so rows
  # do not jump under the cursor and the person's own drag order stands
  # otherwise; mice that want the same keep the order they are in. The block
  # lands where its first member sits now.
  defp sort(state, lines, placed, workspaces) do
    needing = for line <- lines, Sidebar.needs_you?(line), into: MapSet.new(), do: line.mouse_id

    if needing == state.needing do
      state
    else
      reorder(%{state | needing: needing}, lines, placed, workspaces)
    end
  end

  defp reorder(state, lines, placed, workspaces) do
    position = workspaces |> Enum.with_index() |> Map.new(fn {ws, i} -> {ws.workspace_id, i} end)

    members =
      lines
      |> Enum.filter(&Map.has_key?(placed, &1.mouse_id))
      |> Enum.map(&{&1.rank, placed[&1.mouse_id]})
      |> Enum.uniq_by(&elem(&1, 1))

    wanted =
      members |> Enum.sort_by(fn {rank, ws} -> {rank, position[ws]} end) |> Enum.map(&elem(&1, 1))

    current = members |> Enum.map(&elem(&1, 1)) |> Enum.sort_by(&position[&1])

    if wanted == current do
      state
    else
      move(state, wanted, anchor(workspaces, current))
    end
  end

  defp anchor(workspaces, [first | _] = members) do
    block = MapSet.new(members)

    workspaces
    |> Enum.map(& &1.workspace_id)
    |> Enum.drop_while(&(&1 != first))
    |> Enum.find(&(not MapSet.member?(block, &1)))
  end

  defp move(state, ids, before) do
    case state.herdr.move_block(state.socket, ids, before) do
      {:ok, _order} ->
        state

      {:error, reason} ->
        warn_once(state, :move_block, "herdr would not re-sort the mice (#{inspect(reason)})")
    end
  end

  # The person sets away, a focus or a hold from a CLI process that cannot
  # reach this one, so the tick that already rebuilds the board is where a
  # change is noticed, and a lifted mode delivers within `panes_ms` rather
  # than at the next backstop.
  defp notice_mode(state) do
    mode = mode(state)

    if state.last_mode != nil and state.last_mode != mode,
      do: deliver(state),
      else: %{state | last_mode: mode}
  end

  defp mode(state), do: Mode.read(away_path: state.away_path)

  # A fresh board is drawn from herdr's last answer — this one's or the one
  # matching panes fetched, if that was within `panes_ms`.
  #
  # Stamped after the answer, so a herdr that took seconds to give it is not
  # asked again on the very next write.
  defp refresh_board_panes(state) do
    asked_at = state.panes_asked_at

    if asked_at && System.monotonic_time(:millisecond) - asked_at < state.panes_ms do
      state
    else
      panes = safe_list_panes(state)
      %{state | last_panes: panes, panes_asked_at: System.monotonic_time(:millisecond)}
    end
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

  # Dropping a worktree closes its herdr workspace, and herdr says so with
  # `workspace_closed` alone — the panes inside it get no `pane_closed` (herdr
  # 0.8.2, checked on 2026-10-04). The event names no pane, so the house asks
  # herdr again, marks dead whatever it no longer lists (ADR-0026), and redraws
  # the board now rather than on its next build (ADR-0051).
  defp herdr_event("workspace_closed", _data, state) do
    state |> refresh() |> Map.put(:board_built_at, nil) |> write_board()
  end

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

        state = %{
          state
          | panes: matched,
            last_panes: {:ok, panes},
            panes_asked_at: System.monotonic_time(:millisecond)
        }

        {:ok, state, mice}

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

  # Ringing again for an answer not taken, on the same backstop as cleanup: a
  # swallowed doorbell happens inside the pane, so there is nothing to be told
  # about (ADR-0080).
  defp ring(%{socket: nil} = state), do: state

  defp ring(state) do
    %{
      main_checkout: state.main_checkout,
      herdr: state.herdr,
      socket: state.socket,
      panes: state.last_panes,
      main_pane: state.main_pane,
      ring_ms: state.ring_ms,
      mode: mode(state),
      now: DateTime.utc_now()
    }
    |> Doorbell.sweep()
    |> Enum.each(&rang(&1, state))

    state
  end

  defp rang({q, mouse, :rang}, state),
    do: warn(state, "rang #{branch_or_id(mouse, q)}'s doorbell again for ##{q.id}")

  defp rang({q, mouse, :not_taken}, state) do
    branch = branch_or_id(mouse, q)
    warn(state, "#{branch} has not taken its answer to ##{q.id} — told the person")
    not_taken_hoot(state, q, branch)
  end

  defp rang({q, mouse, {:left, {:refused, reason}}}, state) do
    warn(
      state,
      "#{branch_or_id(mouse, q)}'s doorbell for ##{q.id} was refused (#{inspect(reason)})"
    )
  end

  defp rang(_left, _state), do: :ok

  defp branch_or_id(%Mouse{branch: branch}, _q) when is_binary(branch), do: branch
  defp branch_or_id(_mouse, q), do: q.mouse_id

  # A courtesy, as every hoot is: whatever herdr or the desktop does here is
  # swallowed rather than allowed to take the house down.
  defp not_taken_hoot(state, q, branch) do
    notification = Hoot.not_taken(q, Path.basename(state.main_checkout), branch)
    Hoot.send_out(state.herdr, state.socket, state.desktop, notification)
  catch
    _kind, _reason -> :ok
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
    mode = mode(state)
    waiting = Storage.questions()
    fresh_round? = Mode.open_count(waiting, mode) == 0 and Mode.slot(waiting, mode) == nil

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
             branch: entry.branch,
             ran_on: entry.ran_on
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
    state = %{state | last_mode: mode(state)}

    if state.round_timer, do: state, else: to_main_session(state, state.last_mode)
  end

  defp to_main_session(%{main_pane: nil} = state, _mode) do
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

  defp to_main_session(state, mode) do
    case next_to_deliver(mode) do
      nil ->
        release_hold(state)

      %Question{} = question ->
        case main_session_free?(state) do
          {:go, notes, state} -> send_question(state, question, notes, mode)
          {:hold, reason, state} -> hold(state, reason)
        end
    end
  end

  # How long delivery has been holding, and why. The gate is unchanged
  # (ADR-0008, ADR-0047); this only remembers what it decided, so the sidebar
  # can say it (ADR-0058). A hold whose reason changes — mid-turn, then a draft in
  # the box — is one hold that has not let go, so the clock keeps running.
  defp hold(%{held_since: %DateTime{}} = state, reason), do: %{state | held_reason: reason}
  defp hold(state, reason), do: %{state | held_since: now(), held_reason: reason}

  defp release_hold(state), do: %{state | held_since: nil, held_reason: nil}

  # Said only once the hold has outlasted the fuse, and only while something the
  # person has not set aside is actually queued behind it.
  defp held_reason(state, mode) do
    with %DateTime{} = since <- state.held_since,
         true <- DateTime.diff(now(), since, :millisecond) >= state.hold_notice_ms,
         true <- Mode.open_count(Storage.questions(), mode) > 0 do
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

  # What goes next, if the main session will have it: judged against what the
  # person set aside first, then the slot (`Whiska.Delivery.Mode`). A finished
  # line waits for the slot but never holds it: it goes first once the slot is
  # free, and is closed as it is sent.
  defp next_to_deliver(mode), do: Mode.next(Storage.questions(), mode)

  defp main_session_free?(%{socket: nil} = state) do
    state
    |> warn_once(:no_socket, "no herdr socket known — cannot deliver")
    |> then(&{:hold, :unreachable, &1})
  end

  defp main_session_free?(state) do
    case state.herdr.pane(state.socket, state.main_pane) do
      {:ok, %{agent: "claude", agent_status: status}} when status in ["idle", "done"] ->
        box_is_free(state, [])

      {:ok, %{agent: "claude", agent_status: "unknown"}} ->
        box_is_free(state, [:status_unknown])

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
  # read. A `pane.read` herdr refuses is ADR-0008's unavailable signal — deliver
  # anyway.
  defp box_is_free(state, notes) do
    case state.herdr.read_screen(state.socket, state.main_pane) do
      {:ok, screen} ->
        case screen |> Draft.read() |> Draft.hold() do
          {:hold, held} -> {:hold, held, state}
          :go -> {:go, notes, state}
        end

      {:error, _reason} ->
        {:go, notes, state}
    end
  end

  defp send_question(state, question, notes, mode) do
    branch = branch_of(question.mouse_id)
    more = Mode.more(Storage.questions(), mode, question)
    line = Text.compose(question, branch, more, notes)

    case state.herdr.prompt(state.socket, state.main_pane, line) do
      :ok ->
        {:ok, _} = Storage.mark_sent(question.id)
        settle_report(question)
        hoot(state, question, branch, more)
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
  # line, so the two can never disagree about what reached the person — and
  # that holds for the desktop fallback too, since it is decided here, off
  # herdr's answer to this very hoot (ADR-0071).
  #
  # Delivery is the job and the hoot is a courtesy: the question is already
  # recorded sent before this runs, and whatever herdr or the desktop does here
  # is swallowed rather than allowed to fail the delivery or take the house
  # down. `whiska doctor` is where the outcome is read.
  defp hoot(state, question, branch, more) do
    notification = Hoot.compose(question, Path.basename(state.main_checkout), branch, more)
    Hoot.send_out(state.herdr, state.socket, state.desktop, notification)
  catch
    _kind, _reason -> :ok
  end

  # A done report is told once and never waits for an answer: closing it as
  # soon as it is sent means it never holds ADR-0008's one slot.
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
