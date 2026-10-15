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
  the first and only thing that ever fills a mouse's `pane` column (ADR-0028).

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
  (ADR-0009) — and removes the entry (ADR-0007).

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

  A marked stop the hook held because its mouse had a subagent out is released at
  the start of each collection, by any trigger, once the entry's transcript shows
  none out and the mouse idle (its transcript quiet for `settle_ms`) — or half an hour on
  (ADR-0052). A mouse
  still working settles it with its own next stop. It is then collected as any
  entry, and is no missed trigger for the backstop's count.

  A `done` report is recorded closed, and hooted (ADR-0009, ADR-0062); its
  line is typed once nothing waits on the person, and holds nothing
  (ADR-0008). An entry whose worktree is no longer on disk is
  recorded as orphaned rather than delivered. Whatever a mouse
  leaves supersedes its own earlier open or sent questions: it has moved past
  them, and an answer could no longer land. One that held the slot hands it to
  the newer question, which goes next — unless that is a report, which takes
  no part in the queue, so the slot is free.

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
  it too (ADR-0047): there is nowhere for the line to land, and a dialog waiting
  on the person is one of the ways to get there. A box whose contents Whiska
  cannot read is the unreadable signal ADR-0008 rules on, and delivers anyway.

  A hold is remembered — since when, and which half of the gate held — so the
  main checkout's sidebar line can say why nothing is being delivered once it
  has outlasted the fuse (ADR-0082). Only the saying is new: the gate decides exactly as it did.

  The line is typed and a hoot goes out with it (ADR-0062): one desktop
  notification per delivered question, raised in the same breath as the line
  so the two can never disagree, and never raised for a question that is only
  collected or held. It carries the house, the branch, the verb and the id —
  `Whiska.Delivery.Hoot`, which says it in the line's own words. It is a
  courtesy, not the job: a hoot that errors or raises is swallowed, and the
  question stays delivered. It is raised on the desktop, never through herdr,
  and the owl logs what became of each (ADR-0062).

  ## Finished branches (ADR-0062)

  A finished report is hooted once instead, as soon as it is collected and
  nothing the person set aside stands in its way, and its branch is reminded
  while it waits to be finished: at most one hoot per house every `remind_ms`
  (2 h), naming each finished branch with work of its own to land whose last
  hoot is at least that old (`Whiska.Reminder`). Judged after every collection
  and on the backstop, after cleanup has taken down what landed. Each report's
  last hoot is stored, so an owl that restarts owes nothing twice; the house's
  own clock starts when it opens, so a restart reminds no sooner than an owl
  that kept running would have.

  A house tells no other house anything, and nothing is ever typed into
  another repo's session (ADR-0044): herdr's tab bar redraws on its own timer
  and reads what is waiting here off disk.

  The house keeps a line under each of its mice's herdr workspaces, and one
  under its main checkout's (`Whiska.Sidebar`,
  ADR-0082). It reads back what
  herdr is showing every time it asks herdr for its panes and sends whatever
  differs — which is how a line lost to a herdr restart comes back — and sends
  every line again before its TTL runs out, so a line nobody is keeping current
  expires. The mice are re-sorted only when one changes state or a new one
  appears busy, so rows do not move under the cursor otherwise.

  ## Fetching the base (ADR-0087)

  While a mouse's merge request waits, the backstop fetches its base every
  `fetch_ms` (60 s) from when the last fetch started, so a merge on the forge
  reaches the fetched copy cleanup reads. A read that finds the merge request
  merged fetches at once. The fetch runs in a task, one at a time, never in the
  house's own process; a failure waits twice as long before the next, up to
  `fetch_max_ms` (an hour), and is said in the log once until a fetch works
  again.

  ## Reading the forge (ADR-0087)

  The backstop also reads each watched merge request (`Whiska.MergeRequests`)
  every `forge_ms` (60 s) from when its last read started, in a task of its
  own, one at a time. The house keeps each read's row and acts on what it says
  happened: the log says what would wake a mouse, a merge fetches the base. A
  read that fails backs off and is said once. The tools default to the
  application's `:forge_tools`, else the ones installed.
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
  alias Whiska.Doorstep.Entry
  alias Whiska.Git
  alias Whiska.Herdr
  alias Whiska.Layout
  alias Whiska.Ledger
  alias Whiska.MergeRequests
  alias Whiska.Letters
  alias Whiska.MousePane
  alias Whiska.Pickup
  alias Whiska.Pickup.Policy
  alias Whiska.Question.FromOwl
  alias Whiska.Question.Marker
  alias Whiska.Reminder
  alias Whiska.Restart
  alias Whiska.ReviewRound
  alias Whiska.ReviewStart
  alias Whiska.ServiceManager
  alias Whiska.Schema.HouseLetter
  alias Whiska.Schema.MergeRequestRead
  alias Whiska.Schema.Mouse
  alias Whiska.Schema.Question
  alias Whiska.SpecArchive
  alias Whiska.Storage
  alias Whiska.Sidebar
  alias Whiska.Transcript
  alias Whiska.Watch
  alias Whiska.Research

  @global_subscriptions [
    %{type: "pane.closed"},
    %{type: "pane.exited"},
    %{type: "pane.agent_detected"},
    %{type: "workspace.closed"}
  ]

  @gate_screen ".git/whiska/gate-screen"

  @default_backstop_ms 60_000
  @default_resubscribe_ms 5_000
  @default_round_wait_ms 8_000
  @default_retry_ms [2_000, 5_000]
  # The sidebar is checked every second, and a line sent only when its words
  # change, but the board under it is built afresh only every two: what herdr says moves no
  # faster than that, and asking it, the database and every transcript is what
  # a build costs.
  @default_board_ms 1_000
  @default_panes_ms 2_000
  # A sidebar line lives this long unless it is sent again, and is sent again
  # this long after it last was: a dead owl's lines are gone within the TTL,
  # and a live owl gets two tries before one lapses.
  @default_sidebar_ttl_ms 30_000
  @default_sidebar_refresh_ms 20_000
  # How long delivery has to be holding before the sidebar says so (ADR-0082).
  @default_hold_notice_ms 10_000
  # How long a mouse's pane has to have been quiet before a died turn is picked
  # up (ADR-0067). Two backstops, so a laptop waking cannot have a whole fleet
  # picked up on the strength of one reconnection's pane list.
  @default_settle_ms 120_000
  # How long after a doorbell, unanswered by a take, the owl rings it again
  # (ADR-0080). Checked on the backstop, so the
  # real spacing is this to this plus one backstop.
  @default_ring_ms 90_000
  @default_fetch_ms 60_000
  @default_forge_ms 60_000
  @default_forge_timeout_ms 30_000
  @default_fetch_max_ms 3_600_000
  @default_fetch_timeout_ms 60_000
  # How far apart a house's reminders about finished branches are, and how old
  # a branch's last hoot must be before one names it (ADR-0062).
  @default_remind_ms 7_200_000

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
    :fetch_ms,
    :fetch_max_ms,
    :fetch_timeout_ms,
    :forge_ms,
    :remind_ms,
    :reminded_at,
    :away_path,
    :forge_context,
    nothing_to_land: %{},
    fetching: nil,
    fetch_started_at: nil,
    fetch_soon: false,
    reading: nil,
    read_started_at: nil,
    read_due: %{},
    starting: %{},
    picked_now: MapSet.new(),
    restarted: MapSet.new(),
    fetch_due_at: nil,
    fetch_wait_ms: nil,
    fetch_failing: false,
    last_mode: nil,
    last_letter_id: nil,
    held_since: nil,
    held_reason: nil,
    held_id: nil,
    subscription: nil,
    workspaces: nil,
    shown: %{},
    sent_at: %{},
    sorted_on: nil,
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
  after a doorbell an answer not taken is rung again), `:fetch_ms` (how often
  the base is fetched while a merge request waits), `:fetch_max_ms` (the
  longest wait a failing fetch backs off to), `:fetch_timeout_ms` (when a fetch
  still running is killed), `:forge_ms` (how often each merge request is read
  on its forge), `:forge_timeout_ms` (when one forge call still running is
  killed), `:forge_tools` (a forge tool's path by its name, where it is not
  the one installed), `:remind_ms` (how far apart reminders about finished
  branches are, ADR-0062), `:desktop` (where a hoot
  is raised, `Whiska.Desktop.impl/0` by default),
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
          fetch_ms: Keyword.get(opts, :fetch_ms, @default_fetch_ms),
          fetch_max_ms: Keyword.get(opts, :fetch_max_ms, @default_fetch_max_ms),
          fetch_timeout_ms: Keyword.get(opts, :fetch_timeout_ms, @default_fetch_timeout_ms),
          forge_ms: Keyword.get(opts, :forge_ms, @default_forge_ms),
          remind_ms: Keyword.get(opts, :remind_ms, @default_remind_ms),
          reminded_at: DateTime.utc_now(),
          forge_context:
            MergeRequests.context(
              main,
              Keyword.get(opts, :forge_timeout_ms, @default_forge_timeout_ms),
              Keyword.get_lazy(opts, :forge_tools, fn ->
                Application.get_env(:whiska, :forge_tools, %{})
              end)
            ),
          away_path: Keyword.get_lazy(opts, :away_path, &Mode.away_path/0),
          main_pane: Storage.main_pane(),
          last_letter_id: Storage.newest_letter_id()
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

    hide_own_files(state)

    # Kept files an older owl wrote under a header lose it, and their mouse
    # learns their name (ADR-0063).
    SpecArchive.unhead(state.main_checkout)

    # Entries an older owl renamed `.collected` are a second copy of rows.
    Doorstep.sweep_collected(state.main_checkout)

    # Delivery is attempted at open, not only after a collection: reconciling
    # may just have freed ADR-0008's slot by marking a mouse dead that died
    # while the owl was down, and the question behind it should not wait for
    # the backstop's minute. The gate decides, and a collection that started a
    # round holds this one back anyway.
    state =
      state
      |> reconcile_panes()
      |> subscribe()
      |> restart()
      |> collect_now()
      |> deliver()
      |> pick_up()

    Process.send_after(self(), :backstop, state.backstop_ms)
    state = write_board(state)
    Process.send_after(self(), :board, state.board_ms)
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    drop_subscription(state)
    Storage.close(state.repo)
    crashed(state, reason)
  catch
    _kind, _reason -> :ok
  end

  # The owl's Logger is off, so this line is the only trace a crash leaves.
  defp crashed(_state, reason) when reason in [:normal, :shutdown], do: :ok
  defp crashed(_state, {:shutdown, _}), do: :ok
  defp crashed(state, reason), do: warn(state, "the house crashed #{crash(reason)}")

  defp crash({error, [{module, _, _, _} | _] = stacktrace}) when is_atom(module) do
    exception = Exception.normalize(:error, error, stacktrace)
    message = exception |> Exception.message() |> String.replace(~r/\s+/, " ")
    "(#{short(inspect(exception.__struct__) <> ": " <> message)})#{at(stacktrace)}"
  rescue
    _ -> "(#{short(inspect(error, limit: 5))})"
  end

  defp crash(reason), do: "(#{short(inspect(reason, limit: 5))})"

  # The first frame with a file: an undefined function's own frame has none.
  # A frame's arguments can be the whole house state, so only its arity is said.
  defp at(stacktrace) do
    case Enum.find(stacktrace, &has_file?/1) do
      {module, fun, args, location} ->
        " in " <> short(Exception.format_stacktrace_entry({module, fun, arity(args), location}))

      nil ->
        ""
    end
  end

  defp has_file?({_, _, _, location}) when is_list(location),
    do: Keyword.has_key?(location, :file)

  defp has_file?(_frame), do: false

  defp arity(args) when is_list(args), do: length(args)
  defp arity(arity), do: arity

  defp short(text), do: String.slice(text, 0, 300)

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
      |> restart()
      |> collect_on_backstop()
      |> deliver()
      |> clean_up()
      |> remind()
      |> fetch_base()
      |> read_forge()
      |> ring()
      |> pick_up()
      |> review()

    Process.send_after(self(), :backstop, state.backstop_ms)
    {:noreply, state}
  end

  def handle_info({ref, results}, %{fetching: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, fetched(%{state | fetching: nil}, results)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{fetching: %Task{ref: ref}} = state) do
    {:noreply, fetched(%{state | fetching: nil}, [{"the base", {:error, {:crashed, reason}}}])}
  end

  def handle_info({ref, {reads, context}}, %{reading: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, have_read(%{state | reading: nil, forge_context: context}, reads)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{reading: %Task{ref: ref}} = state) do
    warn(state, "reading the forge crashed (#{inspect(reason)}) — trying again next minute")
    {:noreply, %{state | reading: nil}}
  end

  def handle_info({ref, result}, %{starting: starting} = state) when is_map_key(starting, ref) do
    Process.demonitor(ref, [:flush])
    {start, starting} = Map.pop(starting, ref)
    {:noreply, started(%{state | starting: starting}, start, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{starting: starting} = state)
      when is_map_key(starting, ref) do
    {start, starting} = Map.pop(starting, ref)
    {:noreply, started(%{state | starting: starting}, start, {:error, {:crashed, reason}})}
  end

  def handle_info(:board, state) do
    state = state |> notice_letter() |> write_board()
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

  # -- the sidebar (ADR-0082) -------

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
        |> Map.put(:last_board, board)
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
    lines = Sidebar.mice(board, now: DateTime.utc_now())
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

  # The mice re-sort only when one changes state, starts or stops queueing
  # behind another, or appears in a state but idle (ADR-0082): a state changes far less often than a tick,
  # so rows do not jump under the cursor and the
  # person's own drag order stands otherwise; mice that want the same keep the
  # order they are in. The block lands where its first member sits now.
  defp sort(state, lines, placed, workspaces) do
    ranks = Map.new(lines, &{&1.mouse_id, Sidebar.rank(&1)})
    queue = for %{under: holder} = line <- lines, holder, into: %{}, do: {line.mouse_id, holder}
    previous = state.sorted_on
    state = %{state | sorted_on: {ranks, queue}}

    if resort?(previous, ranks, queue), do: reorder(state, lines, placed, workspaces), else: state
  end

  # A mouse that goes is not a change of state, and nor is an idle one that
  # appears: both land in place at the next re-sort. One that appears in any
  # other state re-sorts at once, since it may already be working and would
  # otherwise sit under held mice (ADR-0082).
  defp resort?(nil, _ranks, _queue), do: true

  defp resort?({before, queued}, ranks, queue) do
    queued != queue or
      Enum.any?(ranks, fn {id, rank} ->
        case before do
          %{^id => was} -> was != rank
          _ -> rank != Sidebar.idle_rank()
        end
      end)
  end

  defp reorder(state, lines, placed, workspaces) do
    position = workspaces |> Enum.with_index() |> Map.new(fn {ws, i} -> {ws.workspace_id, i} end)

    # `lines` are in Whiska's order; a mouse the person sorted among its equals
    # (same state, same mode) keeps the place it has in herdr now, and a queued
    # mouse stays right under the mouse holding its question.
    here = Enum.filter(lines, &Map.has_key?(placed, &1.mouse_id))
    held_here = MapSet.new(here, & &1.mouse_id)

    # A queued mouse whose holder has no workspace here sorts on its own.
    {queued, leaders} =
      Enum.split_with(here, &(&1.under && MapSet.member?(held_here, &1.under)))

    leaders = Enum.sort_by(leaders, &{&1.rank, &1.sniff?, position[placed[&1.mouse_id]]})

    members =
      leaders
      |> Enum.flat_map(fn leader ->
        [leader | Enum.filter(queued, &(&1.under == leader.mouse_id))]
      end)
      |> Enum.map(&placed[&1.mouse_id])
      |> Enum.uniq()

    wanted = members
    current = Enum.sort_by(members, &position[&1])

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
  # change is noticed, and a lifted mode delivers — and hoots what it held
  # back about finished branches (ADR-0062) — within `panes_ms` rather than at
  # the next backstop.
  defp notice_mode(state) do
    mode = mode(state)

    if state.last_mode != nil and state.last_mode != mode,
      do: state |> remind() |> deliver(),
      else: %{state | last_mode: mode}
  end

  defp mode(state), do: Mode.read(away_path: state.away_path)

  # `whiska tell` writes a letter from a CLI process in another repo, which
  # cannot reach this one, so a new letter is noticed on the same tick.
  defp notice_letter(state) do
    case Storage.newest_letter_id() do
      newest when newest == state.last_letter_id -> state
      newest -> deliver(%{state | last_letter_id: newest})
    end
  end

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
  # the board now rather than on its next build (ADR-0082).
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

  # A merge request is merged on the forge, where nothing tells the owl, so its
  # base is fetched on the backstop for cleanup to read
  # (ADR-0087). Git runs in a task: a
  # network call never holds the house (ADR-0060).
  defp fetch_base(%{fetching: %Task{}} = state), do: state

  # The wait and the failure already said belong to the merge requests that
  # were waiting: once none is, the next one starts afresh.
  defp fetch_base(state) do
    case merge_requests_waiting() do
      [] ->
        %{state | fetch_due_at: nil, fetch_wait_ms: nil, fetch_failing: false}

      recorded ->
        if is_nil(state.fetch_due_at) or System.monotonic_time(:millisecond) >= state.fetch_due_at,
          do: start_fetch(state, recorded),
          else: state
    end
  end

  defp start_fetch(state, recorded) do
    checkout = state.main_checkout
    timeout = state.fetch_timeout_ms

    %{
      state
      | fetching: Task.async(fn -> fetch_bases(checkout, recorded, timeout) end),
        fetch_started_at: System.monotonic_time(:millisecond),
        fetch_soon: false
    }
  end

  # A fetch already running may have started before the merge, so the one the
  # merge asked for follows it.
  defp fetch_now(%{fetching: %Task{}} = state), do: %{state | fetch_soon: true}
  defp fetch_now(state), do: fetch_base(%{state | fetch_due_at: nil})

  defp merge_requests_waiting do
    for %Mouse{removed_at: nil} = mouse <- Storage.current_mice(),
        Mouse.merge_request_waiting?(mouse),
        is_binary(mouse.path) and File.dir?(mouse.path),
        uniq: true,
        do: mouse.base
  end

  defp fetch_bases(checkout, recorded, timeout) do
    recorded
    |> Enum.map(&Git.base_of(checkout, &1))
    |> Enum.flat_map(fn
      {:ok, base} -> [base]
      {:error, _} -> []
    end)
    |> Enum.uniq()
    |> Enum.map(&{&1, Git.fetch_base(checkout, &1, timeout)})
  end

  defp fetched(%{fetch_soon: true} = state, results),
    do: %{fetched(%{state | fetch_soon: false}, results) | fetch_due_at: nil} |> fetch_base()

  defp fetched(state, results) do
    due = state.fetch_started_at

    case Enum.find(results, &match?({_base, {:error, _}}, &1)) do
      nil ->
        %{state | fetch_due_at: due + state.fetch_ms, fetch_wait_ms: nil, fetch_failing: false}

      {base, {:error, reason}} ->
        wait = min(2 * (state.fetch_wait_ms || state.fetch_ms), state.fetch_max_ms)

        unless state.fetch_failing do
          warn(
            state,
            "fetching #{base} failed (#{inspect(reason)}) — a merge request merged on the " <>
              "forge goes unseen until #{base} is pulled; trying again less often"
          )
        end

        %{state | fetch_due_at: due + wait, fetch_wait_ms: wait, fetch_failing: true}
    end
  end

  # Each read runs in a task, never the house's own process, and talks to the
  # forge only: the rows are read before and written after, here (ADR-0060).
  defp read_forge(%{reading: %Task{}} = state), do: state

  defp read_forge(state) do
    now = System.monotonic_time(:millisecond)
    watched = MergeRequests.watched()
    read_due = Map.take(state.read_due, Enum.map(watched, fn {mouse, _row} -> mouse.mouse_id end))

    due =
      Enum.filter(watched, fn {mouse, _row} -> now >= Map.get(read_due, mouse.mouse_id, now) end)

    case due do
      [] ->
        %{state | read_due: read_due}

      due ->
        context = state.forge_context

        %{
          state
          | reading: Task.async(fn -> MergeRequests.read_each(due, context) end),
            read_started_at: now,
            read_due: read_due
        }
    end
  end

  # A read is folded into its row as it stands now, not as it stood when the
  # read began: a review round may have taken what was kept meanwhile.
  defp have_read(state, reads) do
    now = DateTime.utc_now()
    rows = MergeRequests.reads()

    Enum.reduce(reads, state, fn {mouse, row, result}, state ->
      {attrs, events} = MergeRequests.next(rows[mouse.mouse_id] || row, mouse, result, now)
      wait = MergeRequests.wait_ms(attrs, retry_after(result), state.forge_ms, now)
      state = put_in(state.read_due[mouse.mouse_id], state.read_started_at + wait)

      case MergeRequests.save(attrs) do
        :ok ->
          state = Enum.reduce(events, state, &happened(&1, mouse, &2))
          ask_to_drop(state, mouse, MergeRequests.reads()[mouse.mouse_id])

        {:error, reason} ->
          warn(
            state,
            "could not keep the read of #{label(mouse.mouse_id)}'s merge request (#{inspect(reason)})"
          )

          state
      end
    end)
  end

  defp retry_after({:unknown, _reason, retry_after_ms}), do: retry_after_ms
  defp retry_after(_read), do: nil

  defp happened({:review, _} = event, mouse, state) do
    {:ok, ref} = Whiska.Forge.for_url(mouse.merge_request_url)
    said = MergeRequests.line(event, mouse.branch || mouse.mouse_id, Whiska.Forge.label(ref))
    panes = if state.socket, do: state.herdr.list_panes(state.socket), else: {:error, :no_socket}
    round(state, mouse.mouse_id, said, panes)
  end

  defp happened(event, mouse, state) do
    {:ok, ref} = Whiska.Forge.for_url(mouse.merge_request_url)
    label = Whiska.Forge.label(ref)
    warn(state, MergeRequests.line(event, mouse.branch || mouse.mouse_id, label))

    case event do
      :merged ->
        fetch_now(state)

      :reopened ->
        Storage.close_owls_questions(mouse.mouse_id)
        state

      _other ->
        state
    end
  end

  # Asked once per close, of a worktree that is still there; a reopening
  # clears the stamp. Asked from the row rather than the read that saw the
  # close, so an ask that failed is made at the next read. The question comes
  # in by the doorstep like any other (ADR-0036), collected here and now.
  defp ask_to_drop(
         state,
         %Mouse{removed_at: nil, path: path, merge_request_url: url} = mouse,
         %MergeRequestRead{url: url, state: closed, asked_at: nil}
       )
       when is_binary(path) and closed in ["closed", "gone"] do
    now = DateTime.truncate(DateTime.utc_now(), :second)
    {:ok, ref} = Whiska.Forge.for_url(url)
    label = Whiska.Forge.label(ref)
    why = if closed == "closed", do: :closed, else: :gone

    # Stamped before it is left, so collection finds the owl's own word for it.
    with true <- File.dir?(path) and FromOwl.askable?(mouse),
         :ok <- MergeRequests.save(%{mouse_id: mouse.mouse_id, asked_at: now}),
         {:ok, _file} <- leave_or_unstamp(state, mouse, FromOwl.entry(mouse, label, why, now)) do
      collect_now(state)
    else
      {:error, reason} ->
        warn(state, "could not ask about #{label} (#{inspect(reason)})")
        state

      false ->
        state
    end
  end

  defp ask_to_drop(state, _mouse, _row), do: state

  defp leave_or_unstamp(state, mouse, entry) do
    with {:error, _} = error <- Doorstep.leave(state.main_checkout, entry) do
      MergeRequests.save(%{mouse_id: mouse.mouse_id, asked_at: nil})
      error
    end
  end

  # -- review rounds (ADR-0060) -----------------------------------------------

  # Each review still kept is handed over once its mouse can take it. Only a
  # handing over is said here: a review the read just found was said with why
  # it was kept, and saying so again every minute would bury it.
  defp review(%{socket: nil} = state), do: state

  defp review(state) do
    rows = MergeRequests.reads()

    state =
      rows
      |> Map.values()
      |> Enum.filter(&(&1.state == "open" and round_due?(&1)))
      |> Enum.reduce(state, &round(&2, &1.mouse_id, nil, state.last_panes))

    %{state | picked_now: MapSet.new()}
  end

  defp round_due?(%MergeRequestRead{pending: pending, review_asked_at: asked})
       when is_binary(pending) or not is_nil(asked),
       do: true

  defp round_due?(row) do
    ReviewRound.started?(row) and
      not match?(%Mouse{died_at: nil, removed_at: nil}, Storage.mouse(row.mouse_id))
  end

  defp round(state, mouse_id, said, panes) do
    with %Mouse{} = mouse <- Storage.mouse(mouse_id),
         %MergeRequestRead{} = row <- MergeRequests.reads()[mouse_id],
         {:ok, ref} <- Whiska.Forge.for_url(mouse.merge_request_url) do
      row = settle_review_question(row, mouse, ref)
      pushed? = ReviewRound.pushed?(row, remote_head(state, mouse))

      facts = %{
        mouse: mouse,
        row: row,
        questions: Storage.questions_of(mouse_id),
        panes: if(state.socket, do: panes, else: {:error, :no_socket}),
        main_pane: state.main_pane,
        in_flight?: in_flight?(mouse),
        starting?: Enum.any?(state.starting, fn {_ref, start} -> start.mouse_id == mouse_id end),
        picked_up?: MapSet.member?(state.picked_now, mouse_id),
        pushed?: pushed?
      }

      round = %{
        mouse: mouse,
        row: row,
        ref: ref,
        pushed?: pushed?,
        fresh?: is_binary(said),
        said: said || "#{mouse.branch || mouse_id}: review kept for #{Whiska.Forge.label(ref)}"
      }

      act_on_round(state, ReviewRound.judge(facts), round)
    else
      _ -> state
    end
  end

  defp act_on_round(state, :nothing, round) do
    if round.fresh?, do: warn(state, "#{round.said} — nothing to hand over")
    state
  end

  defp act_on_round(state, {:keep, why}, round) do
    if round.fresh?, do: warn(state, "#{round.said} — kept: #{kept(why)}")
    state
  end

  defp act_on_round(state, {:wake, pane}, %{mouse: mouse, row: row} = round) do
    case wake(state, mouse, row, pane, round.pushed?) do
      :woke ->
        warn(state, "#{round.said} — woke its mouse")

      {:keep, why} ->
        if round.fresh?, do: warn(state, "#{round.said} — kept: #{kept(why)}")

      {:error, reason} ->
        if round.fresh?,
          do: warn(state, "#{round.said} — could not wake its mouse (#{inspect(reason)}), kept")
    end

    state
  end

  defp act_on_round(state, :start, %{mouse: mouse, row: row} = round) do
    warn(state, "#{round.said} — starting a mouse")
    handed = MergeRequestRead.pending(row)
    letter = ReviewRound.letter(mouse, handed)

    {main, via, repo} =
      {state.main_checkout, %{herdr: state.herdr, socket: state.socket}, state.repo}

    task =
      Task.async(fn ->
        Storage.point_at(repo)
        ReviewStart.run(main, mouse, letter, via)
      end)

    start = %{mouse_id: mouse.mouse_id, handed: handed, row: row, pushed?: round.pushed?}
    %{state | starting: Map.put(state.starting, task.ref, start)}
  end

  defp act_on_round(state, {:ask, why}, round) do
    warn(state, "#{round.said} — kept: #{kept(why)}; asked you")
    ask_about_review(state, round.mouse, round.ref, why)
  end

  # The pane is bounded as the doorbell's is (ADR-0080), and the round is
  # stamped before the line is typed and put back if herdr refuses it.
  defp wake(state, mouse, row, pane, pushed?) do
    house = %{herdr: state.herdr, socket: state.socket, main_checkout: state.main_checkout}

    with {:ok, ours} <- MousePane.our_worktrees(house) |> known(),
         true <- MousePane.ours?(mouse, ours) || {:keep, :not_our_worktree},
         :go <- Draft.hold(MousePane.box(pane, house)) |> typing(),
         {:ok, letter} <-
           Letters.write(
             state.main_checkout,
             mouse.path,
             ReviewRound.letter(mouse, MergeRequestRead.pending(row))
           ) do
      Whiska.Spec.ignore(state.main_checkout, ReviewRound.exclude_line()) |> said_or_ok(state)

      with :ok <- MergeRequests.save(round_attrs(state, mouse, row, "woke", pushed?, nil)),
           :ok <- press(state, pane.pane_id, ReviewRound.line(letter)) |> or_put_back(row) do
        :woke
      else
        {:error, _} = error ->
          File.rm(letter)
          error
      end
    end
  end

  defp or_put_back(:ok, _row), do: :ok

  defp or_put_back(error, row) do
    MergeRequests.save(
      Map.take(row, [
        :mouse_id,
        :pending,
        :round_at,
        :round_by,
        :round_ref,
        :round_head,
        :rounds_unpushed
      ])
    )

    error
  end

  defp known(:unknown), do: {:keep, :no_herdr}
  defp known(ok), do: ok

  defp typing({:hold, _reading}), do: {:keep, :typing}
  defp typing(:go), do: :go

  defp said_or_ok({:error, reason}, state),
    do: warn(state, "could not make git ignore #{ReviewRound.replies()} (#{inspect(reason)})")

  defp said_or_ok(:ok, _state), do: :ok

  defp press(state, pane_id, line) do
    state.herdr.prompt(state.socket, pane_id, line)
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp round_attrs(state, mouse, row, by, pushed?, rest) do
    %{
      mouse_id: mouse.mouse_id,
      pending: MergeRequestRead.encode_pending(rest),
      round_at: DateTime.truncate(DateTime.utc_now(), :second),
      round_by: by,
      round_ref: remote_head(state, mouse),
      round_head: row.head_sha,
      rounds_unpushed: ReviewRound.unpushed(row, pushed?)
    }
  end

  defp started(state, start, result) do
    branch = label(start.mouse_id)

    with %Mouse{} = mouse <- Storage.mouse(start.mouse_id),
         {:ok, ref} <- Whiska.Forge.for_url(mouse.merge_request_url) do
      case result do
        {:ok, %{pane: pane}} ->
          row = MergeRequests.reads()[mouse.mouse_id] || start.row
          rest = ReviewRound.rest(MergeRequestRead.pending(row), start.handed)

          MergeRequests.save(
            round_attrs(
              state,
              mouse,
              %{row | head_sha: start.row.head_sha},
              "started",
              start.pushed?,
              rest
            )
          )

          warn(
            state,
            "#{branch}: started a mouse for #{Whiska.Forge.label(ref)}'s review, in #{pane}"
          )

          state

        {:error, reason} ->
          warn(
            state,
            "#{branch}: could not start a mouse for #{Whiska.Forge.label(ref)}'s review " <>
              "(#{inspect(reason)}) — asked you"
          )

          ask_about_review(state, mouse, ref, :start_failed)
      end
    else
      _ -> state
    end
  end

  # Asked once, and stamped before it is left, as the question about a close
  # is (ADR-0087); the stamp holds every round until the question is closed.
  defp ask_about_review(state, mouse, ref, why) do
    now = DateTime.truncate(DateTime.utc_now(), :second)
    entry = FromOwl.review_entry(mouse, Whiska.Forge.label(ref), why, now)

    with true <- FromOwl.askable?(mouse),
         :ok <-
           MergeRequests.save(%{
             mouse_id: mouse.mouse_id,
             review_asked_at: now,
             review_asked_why: Atom.to_string(why)
           }),
         {:ok, _file} <- leave_or_unstamp_review(state, mouse, entry) do
      collect_now(state)
    else
      {:error, reason} ->
        warn(
          state,
          "could not ask about #{Whiska.Forge.label(ref)}'s review (#{inspect(reason)})"
        )

        state

      false ->
        state
    end
  end

  defp leave_or_unstamp_review(state, mouse, entry) do
    with {:error, _} = error <- Doorstep.leave(state.main_checkout, entry) do
      MergeRequests.save(%{mouse_id: mouse.mouse_id, review_asked_at: nil, review_asked_why: nil})
      error
    end
  end

  # The person closing the owl's question about a review, however it closed,
  # is their word to hand review over again: the count starts afresh. A
  # question that never became one in the house after ten minutes is asked
  # again, so a lost entry never holds every round.
  @lost_question_s 600

  defp settle_review_question(
         %MergeRequestRead{review_asked_at: %DateTime{} = at} = row,
         mouse,
         ref
       ) do
    why = String.to_existing_atom(row.review_asked_why)
    text = FromOwl.review_entry(mouse, Whiska.Forge.label(ref), why, at).text

    case Storage.owls_question(mouse.mouse_id, at, text) do
      %Question{status: status} when status not in ["open", "sent"] ->
        reset = %{
          mouse_id: mouse.mouse_id,
          review_asked_at: nil,
          review_asked_why: nil,
          round_at: nil,
          rounds_unpushed: 0
        }

        settle(row, reset)

      nil ->
        if DateTime.diff(DateTime.utc_now(), at) > @lost_question_s,
          do:
            settle(row, %{mouse_id: mouse.mouse_id, review_asked_at: nil, review_asked_why: nil}),
          else: row

      _waiting ->
        row
    end
  end

  defp settle_review_question(row, _mouse, _ref), do: row

  defp settle(row, attrs) do
    case MergeRequests.save(attrs) do
      :ok -> Map.merge(row, attrs)
      {:error, _} -> row
    end
  end

  defp remote_head(state, %Mouse{branch: branch}) when is_binary(branch) do
    case Git.remote_head(state.main_checkout, branch) do
      {:ok, sha} -> sha
      {:error, _} -> nil
    end
  end

  defp remote_head(_state, _mouse), do: nil

  # A turn waiting on its background work is not over, though its pane reads
  # done (ADR-0052): a line typed now would land in the middle of it.
  defp in_flight?(%Mouse{path: path}) when is_binary(path) do
    case Transcript.newest(Transcript.project_dir(path, ServiceManager.user_home())) do
      {file, _mtime} -> file |> Transcript.tail() |> Transcript.in_flight?()
      nil -> false
    end
  end

  defp in_flight?(_mouse), do: false

  defp kept(:asked), do: "you were asked about its review"
  defp kept(:starting), do: "a mouse is starting for it"
  defp kept(:held), do: "its mouse is held"
  defp kept(:waiting_on_you), do: "its mouse is waiting on you"
  defp kept(:answer_not_taken), do: "its mouse has not taken your answer yet"
  defp kept(:picked_up), do: "its mouse was just picked up"
  defp kept(:in_flight), do: "its mouse has background work out"
  defp kept(:working), do: "its mouse is working"
  defp kept(:typing), do: "its prompt box has text in it"
  defp kept(:cap), do: "three rounds in a row pushed nothing"
  defp kept(:died), do: "the mouse started for it ended without a word"
  defp kept(:cannot_ask), do: "it needs you, and its branch's name cannot go in a question"
  defp kept(why), do: "its pane cannot be typed into (#{why})"

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

  defp not_taken_hoot(state, q, branch),
    do: hoot_out(state, Hoot.not_taken(q, Path.basename(state.main_checkout), branch))

  # A mouse herdr restored without its launch flags is started again with
  # them, before anything else is typed into it (ADR-0044, ADR-0069). Each
  # mouse is tried once per owl run, whatever came of it.
  defp restart(%{socket: nil} = state), do: state

  defp restart(state) do
    %{
      main_checkout: state.main_checkout,
      herdr: state.herdr,
      socket: state.socket,
      panes: state.last_panes,
      main_pane: state.main_pane,
      restarted: state.restarted
    }
    |> Restart.sweep()
    |> Enum.reduce(state, &restarted/2)
  end

  defp restarted({mouse_id, :restarted}, state) do
    warn(state, "#{label(mouse_id)} came back from herdr without its launch flags — restarted it")
    tried(state, mouse_id)
  end

  defp restarted({mouse_id, {:left, {:refused, _} = why}}, state),
    do: failed(state, mouse_id, why)

  defp restarted({mouse_id, {:left, {:start_refused, _session, _reason} = why}}, state),
    do: failed(state, mouse_id, why)

  defp restarted({mouse_id, {:left, :exit_timeout = why}}, state),
    do: failed(state, mouse_id, why)

  defp restarted({mouse_id, {:left, :flagged}}, state),
    do: %{state | restarted: MapSet.delete(state.restarted, mouse_id)}

  defp restarted(_left, state), do: state

  defp failed(state, mouse_id, why) do
    warn(
      state,
      "#{label(mouse_id)} came back from herdr without its launch flags and could not be " <>
        "restarted (#{inspect(why)})"
    )

    hoot_out(state, Hoot.not_restarted(label(mouse_id), Path.basename(state.main_checkout)))
    tried(state, mouse_id)
  end

  defp tried(state, mouse_id), do: %{state | restarted: MapSet.put(state.restarted, mouse_id)}

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
    picked = MapSet.new(for {mouse_id, :picked_up} <- outcomes, do: mouse_id)
    state = %{state | picked_now: picked}
    tell_stalls(state)

    # Stamped when the sweep finished, not when it started: the gap the next
    # sweep measures is the time nobody was watching, and a slow tick is time
    # this one was.
    %{state | seen: seen, last_sweep_at: DateTime.utc_now()}
  end

  # The one hoot a run of failed pickups owes the person (ADR-0067): expired
  # logins together, since one `/login` fixes them all, and each other branch
  # on its own. Stamped before the hoot goes, as a finished report's is: a
  # hoot that fails is not owed again, and an owl that restarts owes nothing.
  defp tell_stalls(state) do
    owed =
      Enum.filter(Storage.untold_stalls(), fn m ->
        Policy.owes_hoot?(%{kind: m.stall_kind, retry_at: m.retry_at, failed: m.stall_failed})
      end)

    now = DateTime.utc_now()
    Enum.each(owed, &Storage.set_stall_hooted(&1.mouse_id, now))
    house = Path.basename(state.main_checkout)

    {logins, others} = Enum.split_with(owed, &(&1.stall_kind == "authentication_failed"))

    if logins != [],
      do: hoot_out(state, Hoot.login_expired(Enum.map(logins, &stalled_branch/1), house))

    for m <- others,
        do: hoot_out(state, Hoot.stalled(stalled_branch(m), m.stall_kind, m.stall_failed, house))

    :ok
  end

  defp stalled_branch(%Mouse{branch: branch}) when is_binary(branch), do: branch
  defp stalled_branch(%Mouse{mouse_id: mouse_id}), do: mouse_id

  # The one place a hoot leaves the owl (ADR-0062). A click on it jumps to this
  # house's main session. A courtesy, as every hoot is: whatever the notifier
  # does here is swallowed rather than allowed to take the house down, and
  # logged, since the notifier's own exit 0 is the only proof there is.
  defp hoot_out(state, notification) do
    notification = Map.put(notification, :jump, state.main_checkout)
    warn(state, hoot_outcome(notification.title, Hoot.send_out(state.desktop, notification)))
  catch
    _kind, _reason -> :ok
  end

  defp hoot_outcome(title, {:ok, notifier}), do: ~s(hoot "#{title}" raised by #{notifier})
  defp hoot_outcome(title, {:error, why}), do: ~s(hoot "#{title}" not raised: #{inspect(why)})
  defp hoot_outcome(title, other), do: ~s(hoot "#{title}" answered #{inspect(other)})

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
  # it: the owl deletes only an entry it recorded (ADR-0007). So it is said, once.
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
  # backstop, as it did for weeks (ADR-0036).
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

    released = release_held(state)

    entries =
      state.main_checkout
      |> Doorstep.waiting()
      |> Enum.filter(fn {file, entry} -> collect_entry(state, file, entry) end)

    mice = Enum.map(entries, fn {_file, entry} -> entry.mouse_id end)

    # What the hook held and this pass released is no missed trigger: the
    # backstop's count is of what the idle trigger should have brought.
    collected = length(mice)
    found = Enum.count(entries, fn {file, _entry} -> file not in released end)
    state = match_new_mice(state, mice)

    state =
      cond do
        collected == 0 -> state
        state.round_timer != nil -> state |> stop_retries() |> remind()
        fresh_round? and opened?(mode) -> state |> stop_retries() |> remind() |> start_round()
        true -> state |> stop_retries() |> remind() |> deliver()
      end

    {found, state}
  end

  # A marked stop the hook held because its mouse had a subagent out is released
  # once none is out and the mouse's turn has ended, or half an hour after the
  # stop (ADR-0052). A mouse that is still working settles it itself: its next
  # stop, read by the hook, drops or delivers it. A transcript that cannot be
  # read says nothing is out, the direction every reader of it fails in.
  defp release_held(state) do
    now = DateTime.utc_now()

    for {file, entry} <- Doorstep.held(state.main_checkout),
        releasable?(entry, now, state.settle_ms),
        {:ok, released} <- [release(state, file)],
        do: released
  end

  defp release(state, file) do
    with {:error, reason} = error <- Doorstep.release(file) do
      warn(state, "could not release #{Path.basename(file)} (#{inspect(reason)})")
      error
    end
  end

  # Idle means the transcript has been quiet for `settle_ms`: a mouse's text and
  # the tool call that follows it are separate entries, and in between it looks
  # finished and is not.
  defp releasable?(%Entry{transcript: path, stamped_at: held_at}, now, settle_ms)
       when is_binary(path) do
    case Transcript.tail(path) do
      "" ->
        true

      tail ->
        quiet?(path, now, settle_ms) and
          tail |> Transcript.background() |> Transcript.releases_held?(held_at, now)
    end
  end

  defp releasable?(_entry, _now, _settle_ms), do: true

  defp quiet?(path, now, settle_ms) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} -> DateTime.to_unix(now) - mtime >= div(settle_ms, 1000)
      {:error, _gone} -> true
    end
  end

  # A finished report is closed as it is collected, so a collection of reports
  # alone opens no round.
  defp opened?(mode), do: Mode.open_count(Storage.questions(), mode) > 0

  # A collection is the first the house hears of a mouse that has never been
  # matched to a pane — `collect_entry/3` records the mouse from the entry
  # itself. Left to `refresh/1`'s own triggers the pane column stayed nil until
  # the backstop's minute was up, and in that minute `whiska waiting` said "no
  # pane" and `whiska reply` refused (ADR-0043). So an
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

  # A done report waits on nobody, so it arrives closed (ADR-0009); its hoot is
  # `remind/1`'s, and its line goes once nothing waits (ADR-0008). An entry whose
  # worktree has already gone has nowhere to reply to, so it arrives where the
  # rest of that mouse's questions went — settled if its branch landed,
  # orphaned if it did not (ADR-0064). The owl's question about a review is
  # about the merge request, not the worktree, and waits on the person either
  # way. The mouse is recorded first, so the question of a mouse nobody had
  # heard of is asked of a row that exists.
  defp arriving(_entry, _kind, "owl", true), do: "open"

  defp arriving(entry, kind, asked_by, _review?) do
    cond do
      File.dir?(entry.worktree_root) and kind == "done" -> "closed"
      File.dir?(entry.worktree_root) -> "open"
      asked_by == "owl" -> "closed"
      true -> Storage.terminal_status(entry.mouse_id)
    end
  end

  defp start_round(state) do
    %{state | round_timer: Process.send_after(self(), :round_over, state.round_wait_ms)}
  end

  defp collect_entry(state, file, entry) do
    kind = Marker.classify(entry.text)

    # Judged on the records as they stood before this entry rewrites the mouse.
    {before, read} = {Storage.mouse(entry.mouse_id), MergeRequests.reads()[entry.mouse_id]}
    asked_by = if FromOwl.ours?(entry, before, read), do: "owl"
    review? = FromOwl.asked_about_review?(entry, before, read)

    with {:ok, mouse} <-
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
             status: arriving(entry, kind, asked_by, review?),
             asked_at: DateTime.truncate(entry.stamped_at, :second),
             asked_by: asked_by
           }),
         {:ok, _} <- Storage.supersede_earlier(question),
         :ok <- keep_spec(state, entry, question),
         :ok <- keep_research(state, entry, question),
         :ok <- keep_document(state, entry, question, Storage.mode_of(mouse)),
         :ok <- record_usage(state, entry, question),
         Doorstep.collected(file) do
      true
    else
      {:error, reason} ->
        # Left on the doorstep, uncollected: the next trigger tries again, and
        # nothing is lost in the meantime.
        warn(state, "could not collect #{Path.basename(file)} (#{inspect(reason)})")
        false
    end
  end

  # The question is already recorded, so a copy that cannot be written is said
  # and passed over: holding the entry back would record the question twice.
  defp keep_spec(state, entry, question) do
    case SpecArchive.keep(state.main_checkout, entry) do
      :kept ->
        Storage.mark_spec_sent(question.id)

      :unchanged ->
        :ok

      {:error, reason} ->
        warn(state, "could not keep the spec of question #{question.id} (#{inspect(reason)})")
    end

    with {:error, reason} <- SpecArchive.keep_plan(state.main_checkout, entry) do
      warn(
        state,
        "could not keep the build plan of question #{question.id} (#{inspect(reason)})"
      )
    end

    :ok
  end

  # Like the spec, a research document that cannot be kept is said and passed over.
  defp keep_research(state, entry, question) do
    with {:error, reason} <- SpecArchive.keep_research(state.main_checkout, entry) do
      warn(
        state,
        "could not keep the research document of question #{question.id} (#{inspect(reason)})"
      )
    end

    :ok
  end

  # The message itself, when it is a document, is a research document or a
  # report, and is kept the same way (ADR-0089).
  defp keep_document(state, entry, question, mode) do
    with {:error, reason} <- SpecArchive.keep_document(state.main_checkout, entry, mode) do
      warn(state, "could not keep the report of question #{question.id} (#{inspect(reason)})")
    end

    :ok
  end

  # The same holds for its usage (ADR-0086). The
  # turn is read as it stood at the entry's stamp, so a collection that comes
  # late never counts the turn the mouse started after it.
  defp record_usage(_state, %{transcript: nil}, _question), do: :ok

  defp record_usage(state, entry, question) do
    path = entry.transcript

    if Path.type(path) == :absolute and Path.extname(path) == ".jsonl" and Ledger.readable?(path) do
      Storage.record_usage(question.id, Ledger.turn(path, entry.stamped_at))
    else
      warn(state, "no usage for question #{question.id}: no transcript at #{inspect(path)}")
    end

    :ok
  rescue
    error ->
      warn(state, "no usage for question #{question.id} (#{Exception.message(error)})")
      :ok
  end

  # Every worktree's marker, research document and build plan, and the folder
  # the worktrees sit in, hidden from git through the exclude file every
  # worktree reads. A gitignore of the person's may hide them on one machine;
  # nothing else would, and a worktree whose marker shows as a change is never
  # taken down (ADR-0061). A research document that showed would also read as a
  # change on the branch line, and the investigation's proposal would go
  # unoffered (ADR-0074).
  defp hide_own_files(state) do
    for line <- [
          Whiska.Marker.exclude_line(),
          Research.exclude_line(),
          Whiska.BuildPlan.exclude_line(),
          Layout.exclude_line()
        ],
        {:error, reason} <- [Whiska.Spec.ignore(state.main_checkout, line)] do
      warn(state, "could not hide #{line} from git (#{inspect(reason)})")
    end
  end

  # -- delivery (ADR-0008) -----------------------------------------------------

  # The gate. Every branch that holds returns the state unchanged, so calling
  # this on every trigger is safe; only a delivery changes anything.
  # The sweep runs whatever the gate then decides, a round's wait included: a
  # question nothing can answer must not sit in the count that wait is
  # gathering (ADR-0008).
  defp deliver(state) do
    release_unanswerable(state)
    state = %{state | last_mode: mode(state)}

    if state.round_timer, do: state, else: to_main_session(state, state.last_mode)
  end

  defp to_main_session(%{main_pane: nil} = state, _mode) do
    if Storage.open_count() > 0 or Storage.next_letter() != nil do
      state
      |> warn_once(
        :no_main,
        "questions or a letter are waiting but no main session is recorded — " <>
          "run `whiska start` in the main session's pane"
      )
      |> hold(:unreachable, nil, "no main pane recorded")
    else
      release_hold(state)
    end
  end

  defp to_main_session(state, mode) do
    case {next_letter(mode), next_to_deliver(mode) || next_report(mode)} do
      {%HouseLetter{} = letter, _question} ->
        case letter_line(state, letter) do
          {:ok, line} ->
            case main_session_free?(state) do
              {:go, _notes, state} -> type_letter(state, letter, line)
              {:hold, reason, status, state} -> hold(state, reason, {:letter, letter.id}, status)
            end

          :error ->
            {:ok, _} = Storage.mark_letter_typed(letter.id)

            warn(
              state,
              "letter ##{letter.id} is not typed: its file is no letter of this house's, " <>
                "or its path cannot be typed"
            )

            to_main_session(state, mode)
        end

      {nil, nil} ->
        release_hold(state)

      {nil, %Question{} = question} ->
        case main_session_free?(state) do
          {:go, notes, state} -> type_line(state, question, notes, mode)
          {:hold, reason, status, state} -> hold(state, reason, question.id, status)
        end
    end
  end

  # How long delivery has been holding, and why. The gate is unchanged
  # (ADR-0008, ADR-0047); this only remembers what it decided, so the sidebar
  # can say it (ADR-0082). A hold whose reason changes — mid-turn, then a draft in
  # the box — is one hold that has not let go, so the clock keeps running.
  #
  # It also writes the log line the sidebar cannot: when a hold starts, when
  # its reason changes, and when it ends — with the question, herdr's status for
  # the main pane, and how long it held. An attempt that comes back with the
  # same answer says nothing, so a nine-minute hold is three lines, not nine.
  defp hold(%{held_since: %DateTime{}, held_reason: reason} = state, reason, id, _status),
    do: %{state | held_id: id}

  defp hold(%{held_since: %DateTime{}} = state, reason, id, status) do
    warn(
      state,
      "#{question_label(id)} still gated (gated #{held_for(state)}): now #{reason} " <>
        "(herdr: #{inspect(status)})"
    )

    %{state | held_reason: reason, held_id: id}
  end

  defp hold(state, reason, id, status) do
    warn(state, "#{question_label(id)} gated: #{reason} (herdr: #{inspect(status)})")

    %{state | held_since: now(), held_reason: reason, held_id: id}
  end

  defp release_hold(%{held_since: nil} = state), do: state

  defp release_hold(state) do
    warn(state, "#{question_label(state.held_id)} no longer gated (gated #{held_for(state)})")
    %{state | held_since: nil, held_reason: nil, held_id: nil}
  end

  defp question_label(nil), do: "questions"
  defp question_label({:letter, id}), do: "letter ##{id}"
  defp question_label(id), do: "##{id}"

  defp held_for(%{held_since: since}) do
    case DateTime.diff(now(), since, :second) do
      seconds when seconds < 60 -> "#{seconds}s"
      seconds -> "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
    end
  end

  # Said only once the hold has outlasted the fuse, and only while something the
  # person has not set aside is actually queued behind it.
  defp held_reason(state, mode) do
    with %DateTime{} = since <- state.held_since,
         true <- DateTime.diff(now(), since, :millisecond) >= state.hold_notice_ms,
         true <- Mode.open_count(Storage.questions(), mode) > 0 or next_letter(mode) != nil do
      state.held_reason
    else
      _ -> nil
    end
  end

  defp now, do: DateTime.utc_now()

  # Nothing that cannot be answered may hold the one slot (ADR-0008). A mouse
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
  # person set aside first, then the slot (`Whiska.Delivery.Mode`).
  defp next_to_deliver(mode), do: Mode.next(Storage.questions(), mode)

  # A finished report's line goes once nothing waits on the person, oldest
  # first, and holds nothing once typed (ADR-0008): a question always goes
  # first, and one collected after it goes as soon as the gate lets it.
  defp next_report(mode) do
    if Mode.clear?(Storage.questions(), mode),
      do: Enum.find(Storage.untyped(), &Mode.deliverable?(&1, mode))
  end

  # A letter waits for away and the gate, never for the slot or a focus: it is
  # no mouse's, and a question the person sits on for a day must not hold the
  # person's own words back that long (ADR-0008).
  defp next_letter(%{away?: true}), do: nil
  defp next_letter(_mode), do: Storage.next_letter()

  defp main_session_free?(%{socket: nil} = state) do
    state
    |> warn_once(:no_socket, "no herdr socket known — cannot deliver")
    |> then(&{:hold, :unreachable, "no herdr socket", &1})
  end

  defp main_session_free?(state) do
    case state.herdr.pane(state.socket, state.main_pane) do
      {:ok, %{agent: "claude", agent_status: status}} when status in ["idle", "done"] ->
        box_is_free(state, [], status)

      {:ok, %{agent: "claude", agent_status: "unknown"}} ->
        box_is_free(state, [:status_unknown], "unknown")

      {:ok, %{agent: "claude", agent_status: status}} ->
        {:hold, :mid_turn, status, state}

      {:ok, %{agent: nil}} ->
        state
        |> warn_once(
          :main_dead,
          "the main session's pane #{state.main_pane} is not running Claude — " <>
            "questions are held; run `whiska start` where it is"
        )
        |> then(&{:hold, :unreachable, "no agent in the pane", &1})

      {:ok, %{agent: other}} ->
        state
        |> warn_once(:main_dead, "the main session's pane runs #{other}, not Claude — held")
        |> then(&{:hold, :unreachable, "pane runs #{other}", &1})

      {:error, reason} ->
        state
        |> warn_once(
          :main_lookup,
          "could not ask herdr about the main pane (#{inspect(reason)})"
        )
        |> then(&{:hold, :unreachable, "pane lookup failed", &1})
    end
  end

  # One file, overwritten on every hold about the box, so what the gate saw is
  # still there to read once the hold is over. The screen holds whatever the
  # person had typed, so it stays out of the log and out of reach of anyone
  # else on the machine. Best effort: a file that cannot be written must never
  # change what the gate decides.
  defp keep_screen(state, screen) do
    file = Path.join(state.main_checkout, @gate_screen)
    tmp = file <> ".tmp-#{System.unique_integer([:positive])}"

    dir = Path.dirname(file)

    with :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(dir, 0o700),
         :ok <- File.write(tmp, screen),
         :ok <- File.chmod(tmp, 0o600),
         :ok <- File.rename(tmp, file) do
      :ok
    else
      error ->
        File.rm(tmp)
        error
    end
  end

  # The second half of the gate (ADR-0047). herdr's idle is the model's word,
  # not the person's: a half-typed prompt sits in the box while the pane is
  # every bit as idle, and a line typed into that box lands inside the draft or
  # submits it. The screen is the only place that shows it, so the screen is
  # read. A `pane.read` herdr refuses is ADR-0008's unavailable signal — deliver
  # anyway.
  defp box_is_free(state, notes, status) do
    case state.herdr.read_screen(state.socket, state.main_pane) do
      {:ok, screen} ->
        case screen |> Draft.read() |> Draft.hold() do
          {:hold, held} ->
            keep_screen(state, screen)
            {:hold, held, status, state}

          :go ->
            {:go, notes, state}
        end

      {:error, _reason} ->
        {:go, notes, state}
    end
  end

  defp type_line(state, question, notes, mode) do
    branch = branch_of(question.mouse_id)
    more = Mode.more(Storage.questions(), mode, question)
    line = Text.compose(question, branch, more, notes)

    case state.herdr.prompt(state.socket, state.main_pane, line) do
      :ok ->
        delivered(state, question, branch, more)
        %{release_hold(state) | warned: MapSet.new()}

      {:error, reason} ->
        # Stays open, and stays held: a delivery herdr keeps refusing is the
        # silence ADR-0082 exists for, not a clean slate.
        state
        |> warn_once(
          :prompt_failed,
          "could not deliver ##{question.id} (#{inspect(reason)}) — will retry"
        )
        |> hold(:unreachable, question.id, "herdr refused the prompt")
    end
  end

  # A finished report was hooted as it was collected (ADR-0062), so its line
  # goes without one, and stays closed: only its stamp says it was typed.
  defp delivered(_state, %Question{kind: "done", status: "closed"} = report, _branch, _more),
    do: :ok = Storage.typed([report.id], DateTime.utc_now())

  defp delivered(state, question, branch, more) do
    {:ok, _} = Storage.mark_sent(question.id)
    hoot(state, question, branch, more)
  end

  # The row is written by another repo's CLI and the folder is reachable by
  # this repo's mice, so the path is checked here, where it is typed.
  defp letter_line(state, letter) do
    if Letters.in_house?(state.main_checkout, letter.path),
      do: Text.letter(letter.from_repo, letter.path),
      else: :error
  end

  defp type_letter(state, letter, line) do
    case state.herdr.prompt(state.socket, state.main_pane, line) do
      :ok ->
        {:ok, _} = Storage.mark_letter_typed(letter.id)
        %{release_hold(state) | warned: MapSet.new()}

      {:error, reason} ->
        state
        |> warn_once(
          :prompt_failed,
          "could not type letter ##{letter.id} (#{inspect(reason)}) — will retry"
        )
        |> hold(:unreachable, {:letter, letter.id}, "herdr refused the prompt")
    end
  end

  # The hoot (ADR-0062), raised from inside the same branch that typed the
  # line, so the two can never disagree about what reached the person.
  #
  # Delivery is the job and the hoot is a courtesy: the question is already
  # recorded sent before this runs, and whatever the desktop does here is
  # swallowed rather than allowed to fail the delivery or take the house down.
  # The owl's log and `whiska doctor` are where the outcome is read.
  defp hoot(state, question, branch, more),
    do: hoot_out(state, Hoot.compose(question, Path.basename(state.main_checkout), branch, more))

  # Finished branches (ADR-0062): each report's finish hoot once nothing the
  # person set aside stands in its way, and a reminder at most every
  # `remind_ms`. Stamped before the hoot goes, as a delivery is recorded sent
  # before its hoot: a hoot that fails is not owed again. With no herdr socket
  # nothing is hooted or stamped, so nothing owed is lost.
  defp remind(%{socket: nil} = state), do: state

  defp remind(state) do
    now = DateTime.utc_now()

    finished = Storage.finished()

    due =
      Reminder.due(Enum.uniq_by(Storage.unhooted() ++ finished, & &1.id), %{
        mode: mode(state),
        now: now,
        remind_ms: state.remind_ms,
        reminded_at: state.reminded_at,
        nothing_to_land: state.nothing_to_land,
        work?: &Reminder.work?(state.main_checkout, &1.mouse)
      })

    nothing_to_land =
      state.nothing_to_land
      |> Map.take(Enum.map(finished, & &1.id))
      |> Map.merge(Map.new(due.nothing_to_land, &{&1.id, now}))

    state = %{state | nothing_to_land: nothing_to_land}

    :ok = Storage.hooted(Enum.map(due.finish, & &1.id), now)
    {quiet, told} = Enum.split_with(due.finish, &quiet_round?(state, &1))
    :ok = Storage.typed(Enum.map(quiet, & &1.id), now)
    Enum.each(told, &hoot(state, &1, branch_of(&1.mouse_id), %{open: 0}))

    case due.remind do
      [] ->
        state

      named ->
        :ok = Storage.hooted(Enum.map(named, & &1.id), now)
        reminder_hoot(state, named, now)
        %{state | reminded_at: now}
    end
  end

  # The first report after a review round the owl handed over ends that round,
  # and one that pushed nothing has nothing for the person to look at: it is
  # counted as hooted and typed, silently (ADR-0062).
  defp quiet_round?(state, %Question{mouse_id: mouse_id, id: id}) do
    with %MergeRequestRead{round_at: %DateTime{} = at, round_by: by} = row
         when by in ["woke", "started"] <- MergeRequests.reads()[mouse_id],
         %Mouse{} = mouse <- Storage.mouse(mouse_id),
         %Question{id: ^id} <-
           mouse_id
           |> Storage.questions_of()
           |> Enum.find(&(&1.kind == "done" and DateTime.compare(&1.asked_at, at) != :lt)) do
      not ReviewRound.pushed?(row, remote_head(state, mouse))
    else
      _ -> false
    end
  end

  defp reminder_hoot(state, reports, now),
    do: hoot_out(state, Hoot.reminder(reports, Path.basename(state.main_checkout), now))

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
    Whiska.Owl.Log.line("whiska [#{Path.basename(state.main_checkout)}]: #{message}")
  end
end
