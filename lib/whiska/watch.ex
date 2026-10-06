defmodule Whiska.Watch do
  @moduledoc """
  The board: what every mouse in this house is doing, one row each.

  ADR-0051 puts it in this repo's Claude Code statusline, which is as many
  lines as the script prints. `whiska mice` answers the same question when
  asked; this answers it without being asked, in front of the person, while
  they work on something else.

  A row is branch, herdr's status, and one column of detail — the question
  waiting on the person if there is one, otherwise the mouse's topic, and
  otherwise what it is doing (`Whiska.Watch.Transcript`) — and, on a working
  mouse's row, a ticker that moves one frame per redraw so a frozen board can be
  told from a quiet one.

  The topic is herdr's `terminal_title_stripped`, the short summary Claude Code
  keeps of what a session is working on — "Order builder for distributors". The
  last tool call is what the person needs only when the mouse is not getting on
  with it: blocked at a dialog, or working and silent for two minutes
  (ADR-0051's addendum of 2026-10-02).

  Live mice first, ordered by how much they want the person: waiting, blocked,
  working, then the quiet ones. Five rows, unless more than five mice are
  waiting — the cap gives way rather than hide a question, which is the one
  failure a board must not have.

  A dead mouse (ADR-0026) has no row at all: its worktree is gone, and a branch
  the person dropped is not something they want to keep looking at. What it left
  behind is not lost — it is counted in a `🐱 n orphaned` line of its own, under
  the `🐱 n waiting` line, and read in full with `whiska questions`. The two
  counts are never added together: an orphaned question has nowhere to reply, so
  calling it waiting tells the person to answer something they cannot, and
  disagrees with `whiska waiting`, which says nothing needs them. Nothing here
  acts — the board only reports.
  """

  alias Whiska.Delivery.Mode
  alias Whiska.Herdr
  alias Whiska.Layout
  alias Whiska.Mice
  alias Whiska.Question.Marker
  alias Whiska.Questions
  alias Whiska.Schema.Mouse
  alias Whiska.Schema.Question
  alias Whiska.Storage
  alias Whiska.Watch.Ink
  alias Whiska.Watch.Text
  alias Whiska.Watch.Transcript

  @board_max 5
  @phrase_max 60
  @branch_max 24
  # How much of the orphan line the names may take. The detail column is the
  # one that can already run long, so the line under it is kept to the same
  # phrase budget and whatever is left over is summed into `+n more`.
  @orphans_max 60

  # The ticker: proof the board is being redrawn, on the rows where a still
  # picture and a frozen one look the same. One frame per snapshot the owl
  # writes, so at ADR-0051's one second the cycle takes three.
  @frames ["·", "··", "···"]
  @ticker_width @frames |> Enum.map(&String.length/1) |> Enum.max()

  # Two minutes of nothing written to a transcript, on a row that says the mouse
  # is working. Claude Code appends every few seconds while a turn runs, so this
  # is a long tool call or a stall — the one case where a raw tool call says
  # more than a topic. Short enough to catch a stall, long enough that an
  # ordinary full test run does not flip the column.
  @stuck_after 120

  @waiting ["open", "sent"]
  @orphaned "orphaned"

  @typedoc "One line of the board, already rendered as words."
  @type row :: %{
          mouse_id: String.t(),
          question_id: pos_integer() | nil,
          branch: String.t(),
          status: String.t(),
          elapsed: String.t(),
          detail: String.t(),
          asked: asked() | nil,
          started_at: DateTime.t(),
          picked_up_at: DateTime.t() | nil
        }

  @typedoc """
  What a row's question is waiting on: the person, since `sent_at` when it holds
  the delivery slot, or the question that does, `behind`. Kept apart from the
  words so a retime can re-spell the age without reading the database again.
  """
  @type asked :: %{
          pointer: String.t(),
          sent_at: DateTime.t() | nil,
          behind: pos_integer() | nil,
          waits: nil | :away | {:focus, String.t()}
        }

  @typedoc "What one dead branch is called on the board, and how many questions it left."
  @type orphan_name :: %{name: String.t(), count: pos_integer()}

  @typedoc "Why delivery is holding, when it has been holding long enough to say."
  @type held :: :typing | :no_box | :mid_turn | :unreachable | nil

  @typedoc """
  `more` is how many live mice the cap left off; `waiting` what no row covers
  and the person can still answer; `orphaned` what nothing can act on any more,
  with `orphan_names` naming the branches those came off; `held` why the gate
  is not delivering; `away?` and `focus` what the person set aside — the
  focused mouse named by its branch.
  """
  @type t :: %{
          rows: [row()],
          more: non_neg_integer(),
          waiting: non_neg_integer(),
          orphaned: non_neg_integer(),
          orphan_names: [orphan_name()],
          held: held(),
          away?: boolean(),
          focus: String.t() | nil
        }

  @doc """
  The board for the house at `main_checkout`.

  Options: `:herdr_socket` (defaults to `HERDR_SOCKET_PATH`), and `board/2`'s
  `:activity`.
  """
  @spec house(Path.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def house(main_checkout, opts \\ []) do
    socket = Keyword.get_lazy(opts, :herdr_socket, &Herdr.socket_path/0)

    with {:ok, handle} <- Storage.open(main_checkout) do
      try do
        {:ok, from_house(Keyword.put(opts, :panes, ask_herdr(socket)))}
      after
        Storage.close(handle)
      end
    end
  end

  @doc """
  The board for the house this process is already pointed at.

  Rows come from `Whiska.Storage.alive_mice/0`, which is the set `whiska mice`
  lists, so the two cannot disagree about what is running here. A dead mouse's
  orphaned questions are read as well: they have no row, and nobody can answer
  them, but they are still open and the count underneath says so in its own
  words.

  Options are `board/2`'s, plus `:away_path` for a mode read here rather than
  handed in.
  """
  @spec from_house(keyword()) :: t()
  def from_house(opts \\ []) do
    questions = Storage.questions() ++ Storage.orphaned_questions()

    board(
      Storage.alive_mice(),
      opts
      |> Keyword.put(:questions, questions)
      |> Keyword.put_new_lazy(:picked_up, &Storage.picked_up/0)
      |> Keyword.put_new_lazy(:mode, fn ->
        Mode.read(away_path: Keyword.get_lazy(opts, :away_path, &Mode.away_path/0))
      end)
    )
  end

  defp ask_herdr(nil), do: :no_socket
  defp ask_herdr(socket), do: Herdr.impl().list_panes(socket)

  @doc """
  The board for a house's mice.

  Options: `:questions`, its waiting and orphaned questions, counted apart;
  `:panes`, herdr's answer in `Whiska.Mice.panes/0` form; `:activity`, what a
  mouse is doing and how long it has been silent,
  `Whiska.Watch.Transcript.activity/1` unless a test pins it; `:held`, why
  the gate is not delivering (ADR-0058); `:mode`, what the person set aside
  (`Whiska.Delivery.Mode.t/0`, nothing by default); `:picked_up`, when each
  branch the owl picked up was picked up (ADR-0067); `:now`, what to measure
  each mouse's age against.
  """
  @spec board([Mouse.t()], keyword()) :: t()
  def board(mice, opts \\ []) do
    questions = Keyword.get(opts, :questions, [])
    panes = Keyword.get(opts, :panes, :no_socket)
    activity = Keyword.get(opts, :activity, &Transcript.activity(&1.path))
    picked_up = Keyword.get(opts, :picked_up, %{})
    mode = Keyword.get(opts, :mode, Mode.none())
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    {orphaned, live} = Enum.split_with(questions, &(&1.status == @orphaned))
    by_mouse = live |> Enum.reverse() |> Map.new(&{&1.mouse_id, &1})
    slot = Mode.slot(live, mode)
    focus = focus_name(mice, mode)
    context = %{slot: slot, mode: mode, focus: focus, now: now}

    {rows, more} =
      mice
      |> Enum.filter(&is_nil(&1.died_at))
      |> Enum.map(
        &row(&1, by_mouse[&1.mouse_id], panes, activity, picked_up[&1.mouse_id], context)
      )
      |> Enum.sort_by(&rank/1)
      |> cap()

    %{
      rows: rows,
      more: more,
      waiting: live |> Enum.reject(&(Mode.waits(&1, mode) == :held)) |> uncovered(rows),
      orphaned: length(orphaned),
      orphan_names: orphan_names(orphaned),
      held: Keyword.get(opts, :held),
      away?: mode.away?,
      focus: focus
    }
  end

  # The focused mouse by the name the person typed; the id names nothing to them.
  defp focus_name(_mice, %{focus: nil}), do: nil

  defp focus_name(mice, %{focus: mouse_id}) do
    case Enum.find(mice, &(&1.mouse_id == mouse_id)) do
      %Mouse{branch: branch} when is_binary(branch) -> branch
      _ -> mouse_id
    end
  end

  # A held mouse's row is a quiet one whatever its question says: the person
  # set it aside, so nothing on it is waiting on them, and its row neither
  # ranks first nor is counted nor is yellow.
  defp row(%Mouse{held_at: %DateTime{}} = mouse, question, panes, activity, picked_up, context) do
    detail =
      case question do
        %Question{status: status, id: id} = q when status in @waiting ->
          pointed("held · ##{id}", Text.plain(Marker.pointer(q.text), @phrase_max))

        _ ->
          detail(nil, nil, pane(mouse, panes), "held", picked_up, context.now, fn ->
            activity.(mouse)
          end)
      end

    %{
      mouse_id: mouse.mouse_id,
      question_id: nil,
      branch: mouse.branch || mouse.mouse_id,
      status: "held",
      elapsed: elapsed(mouse.created_at, context.now),
      detail: detail,
      asked: nil,
      started_at: mouse.created_at,
      picked_up_at: nil
    }
  end

  defp row(mouse, question, panes, activity, picked_up, context) do
    pane = pane(mouse, panes)
    status = status(pane)
    asked = asked(question, context)
    now = context.now

    %{
      mouse_id: mouse.mouse_id,
      question_id: question_id(question),
      branch: mouse.branch || mouse.mouse_id,
      status: status,
      elapsed: elapsed(mouse.created_at, now),
      detail: detail(question, asked, pane, status, picked_up, now, fn -> activity.(mouse) end),
      asked: asked,
      started_at: mouse.created_at,
      picked_up_at: if(question_id(question), do: nil, else: picked_up)
    }
  end

  @doc """
  The same board, its clock moved to `now`: the elapsed column, a picked-up age
  and how long a sent question has waited on the person, and nothing else.

  The house writes the board every second but reads herdr, the database and
  each mouse's transcript only every other write; in between, this is what it
  writes. Every age is re-spelled from the timestamps the row was built from,
  so a re-timed row says exactly what a fresh one would. A queued row's words
  name another question, and only a rebuild can see that one answered, so they
  are left as they were.
  """
  @spec retime(t(), DateTime.t()) :: t()
  def retime(board, now) do
    %{board | rows: Enum.map(board.rows, &retime_row(&1, now))}
  end

  defp retime_row(%{picked_up_at: %DateTime{} = at} = row, now),
    do: %{row | elapsed: elapsed(row.started_at, now), detail: picked_up(at, now)}

  defp retime_row(%{asked: %{sent_at: %DateTime{}} = asked} = row, now),
    do: %{row | elapsed: elapsed(row.started_at, now), detail: asked(row.question_id, asked, now)}

  defp retime_row(row, now), do: %{row | elapsed: elapsed(row.started_at, now)}

  # How long this mouse has been going, in `whiska mice`'s own spelling — the
  # board and the command answer the same question about the same records, and
  # two spellings of `1h 33m` would be two answers.
  defp elapsed(started_at, now), do: Mice.format_uptime(DateTime.diff(now, started_at))

  defp question_id(%Question{status: status, id: id}) when status in @waiting, do: id
  defp question_id(_other), do: nil

  defp pane(mouse, {:ok, panes}) do
    Enum.find(
      panes,
      &(&1.agent != nil and is_binary(&1.cwd) and Layout.inside?(&1.cwd, mouse.path))
    )
  end

  defp pane(_mouse, _unreachable), do: :unreachable

  defp status(nil), do: "no pane"
  defp status(:unreachable), do: "?"
  defp status(pane), do: said_status(pane.agent_status)

  # herdr's `done` is the same state as `idle` in a tab the person has not
  # looked at, which every mouse works in (ADR-0026 note in `Whiska.Owl.House`).
  defp said_status("done"), do: "idle"
  defp said_status("unknown"), do: "?"
  defp said_status(status), do: status

  # A question is waiting on the person only once it is the one they were told:
  # the sent one, or the next to go when nothing is sent. Everything else is
  # queued behind the slot's holder (ADR-0008), or waits behind what the person
  # set aside, and saying "waiting on you" on it too hides the one answer that
  # frees the queue.
  defp asked(%Question{status: status} = question, context) when status in @waiting do
    %{
      pointer: Text.plain(Marker.pointer(question.text), @phrase_max),
      sent_at: if(status == "sent", do: question.sent_at),
      behind: Questions.behind(question, context.slot),
      waits: waits(question, context)
    }
  end

  defp asked(_no_question, _context), do: nil

  # Only an open question waits behind the mode: a sent one was delivered, and
  # is waiting on the person whatever they set aside since.
  defp waits(%Question{status: "open"} = question, %{mode: mode, focus: focus}) do
    case Mode.waits(question, mode) do
      :away -> :away
      {:focus, _mouse_id} -> {:focus, focus}
      _ -> nil
    end
  end

  defp waits(_sent, _context), do: nil

  defp detail(%Question{} = question, %{} = asked, _pane, _status, _picked_up, now, _activity),
    do: asked(question.id, asked, now)

  # News, and only while it is news: the turn the owl started has not ended, so
  # the row says a person did not ask for this one (ADR-0067). `whiska mice`
  # keeps saying it afterwards.
  defp detail(_question, _asked, _pane, _status, %DateTime{} = picked_up, now, _activity),
    do: picked_up(picked_up, now)

  defp detail(_question, _asked, pane, status, _picked_up, _now, activity) do
    %{action: action, silent_for: silent_for} = activity.()
    topic = topic(pane)
    doing = doing(action)

    if stuck?(status, silent_for),
      do: doing || topic || "",
      else: topic || doing || ""
  end

  defp asked(id, %{waits: :away} = asked, _now),
    do: pointed("waits: away · ##{id}", asked.pointer)

  defp asked(id, %{waits: {:focus, name}} = asked, _now),
    do: pointed("waits: focus on #{branch(name)} · ##{id}", asked.pointer)

  # The sent question carries how long it has waited, not the mouse's age in
  # the elapsed column: one left unanswered for hours holds every other question
  # back, and should not read like one told a minute ago.
  defp asked(_id, %{behind: behind} = asked, _now) when is_integer(behind),
    do: pointed("queued behind ##{behind}", asked.pointer)

  defp asked(id, %{sent_at: %DateTime{} = at} = asked, now),
    do:
      pointed(
        "waiting on you for #{Mice.format_uptime(DateTime.diff(now, at))} · ##{id}",
        asked.pointer
      )

  defp asked(id, asked, _now), do: pointed("waiting on you · ##{id}", asked.pointer)

  defp pointed(said, ""), do: said
  defp pointed(said, pointer), do: ~s(#{said} · "#{pointer}")

  defp picked_up(at, now), do: "picked up #{Mice.format_uptime(DateTime.diff(now, at))} ago"

  defp stuck?("blocked", _silent_for), do: true
  defp stuck?("working", silent_for), do: is_integer(silent_for) and silent_for >= @stuck_after
  defp stuck?(_quiet, _silent_for), do: false

  defp doing({:tool, phrase}), do: phrase
  defp doing({:said, sentence}), do: ~s("#{sentence}")
  defp doing(nil), do: nil

  # The title is a mouse's own free text and arrives in some panes with the
  # agent's status glyph still on the front, so the topic starts at the title's
  # first letter or digit and `Whiska.Watch.Text` does the rest. A title with
  # neither is all glyph, and says nothing a row could show.
  defp topic(pane) when is_map(pane) do
    case pane |> Map.get(:title) |> glyphless() |> Text.plain(@phrase_max) do
      "" -> nil
      topic -> topic
    end
  end

  defp topic(_paneless), do: nil

  defp glyphless(title) when is_binary(title),
    do: String.replace(title, ~r/^[^\p{L}\p{N}]+/u, "")

  defp glyphless(_absent), do: ""

  # Off the question's own id, never off the rendered words: a mouse's topic is
  # free text it can set, and a row that sorted itself to the top by saying
  # "waiting on you" would be a forged question, exempt from the cap and
  # answerable by nothing.
  defp rank(%{question_id: id}) when is_integer(id), do: 0
  defp rank(%{status: "blocked"}), do: 1
  defp rank(%{status: "working"}), do: 2
  defp rank(_quiet), do: 3

  # The cap gives way to a question rather than hide one: five rows is a
  # preference about height, and a mouse waiting on the person is the thing the
  # board exists to show (ADR-0051).
  defp cap(rows) do
    {waiting, quiet} = Enum.split_with(rows, &(rank(&1) == 0))
    room = max(@board_max - length(waiting), 0)

    {waiting ++ Enum.take(quiet, room), max(length(quiet) - room, 0)}
  end

  # Every answerable question a row does not carry, so nothing waiting can leave
  # the board without being counted: a mouse the cap left off, and a mouse whose
  # record is gone. Orphans are counted on their own line, never here.
  defp uncovered(questions, rows) do
    shown = MapSet.new(rows, & &1.question_id)

    questions
    |> Enum.reject(&MapSet.member?(shown, &1.id))
    |> length()
  end

  # Which branches the orphans came off, oldest first, each named once with how
  # many it left. An orphan's mouse and worktree are gone, but its record is not
  # (ADR-0007), so the branch — the name the person recognises, and the one
  # `whiska questions` prints for the same question — outlives both. A record
  # that kept no branch is named by the question's own id, which is the handle
  # `whiska questions <id>` takes; its `mouse_id` is an opaque marker id
  # (ADR-0002) and would name nothing.
  defp orphan_names(questions) do
    keys = Enum.map(questions, &orphan_key/1)
    counts = Enum.frequencies(keys)

    keys |> Enum.uniq() |> Enum.map(&%{name: said(&1), count: counts[&1]})
  end

  # Two branches are two names however alike they look: the grouping is on the
  # whole branch, and the cut to the board's column comes after it, so a pair
  # that shares the first 23 characters is not reported as one branch that left
  # two questions.
  defp orphan_key(%Question{mouse: %Mouse{branch: branch}, id: id}) when is_binary(branch) do
    if branch(branch) == "", do: {:question, id}, else: {:branch, branch}
  end

  defp orphan_key(%Question{id: id}), do: {:question, id}

  defp said({:branch, branch}), do: branch(branch)
  defp said({:question, id}), do: "##{id}"

  @doc """
  The board as the statusline draws it. Empty when the house is quiet.

  Options: `:frame`, which frame of the ticker a working row carries, counted in
  boards written rather than in seconds.

  Only a working mouse ticks. An idle one, one blocked, one waiting on the
  person, and one herdr cannot account for are all still — on those rows the
  board is saying nothing is happening, and a moving dot would say the
  opposite. A stale board is still for free: nobody is writing it, so the frame
  stops.

  Without a `:frame` there is no ticker and no column for one: a board printed
  once, by `whiska watch`, has nothing refreshing behind it, and a dot that can
  never move says the opposite of what a ticker is for.
  """
  @spec render(t(), keyword()) :: String.t()
  def render(board, opts \\ [])

  def render(
        %{rows: [], more: 0, waiting: 0, orphaned: 0, held: nil, away?: false, focus: nil},
        _
      ),
      do: ""

  def render(%{rows: rows, more: more, waiting: waiting, orphaned: orphaned} = board, opts) do
    tick = Keyword.get(opts, :frame)
    widths = widths(rows, tick)

    (Enum.map(rows, &line(&1, widths, tick)) ++
       [
         more_line(more),
         waiting_line(waiting, board),
         orphaned_line(orphaned, Map.get(board, :orphan_names, []))
       ])
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp widths(rows, tick) do
    %{
      branch: width(rows, &String.length(branch(&1.branch))),
      status: width(rows, &String.length(&1.status)),
      elapsed: width(rows, &String.length(&1.elapsed)),
      # The column is as wide as the longest frame and is there whether or not
      # anything is working, so a row's detail sits in the same place while the
      # dots grow, and stays there when the last working mouse stops.
      ticker: if(is_integer(tick), do: @ticker_width, else: 0)
    }
  end

  defp width([], _of), do: 0
  defp width(rows, of), do: rows |> Enum.map(of) |> Enum.max()

  # A column is as wide as the words in it and the codes sit inside that width:
  # an escape is not a character the person sees, so counting one would push the
  # detail column sideways and let a branch past the cap that cuts it.
  defp line(row, widths, tick) do
    branch = branch(row.branch)

    text =
      "🐭 " <>
        pad(Ink.cyan(branch), branch, widths.branch) <>
        "  " <>
        String.pad_trailing(row.status, widths.status) <>
        "  " <>
        pad(Ink.dim(row.elapsed), row.elapsed, widths.elapsed) <>
        "  " <> ticker(row, widths.ticker, tick) <> detail(row)

    String.trim_trailing(text)
  end

  defp pad(inked, words, width),
    do: inked <> String.duplicate(" ", max(width - String.length(words), 0))

  # The question is the one thing on the board the person has to act on, so it
  # is the one thing in yellow; what a mouse is doing stays plain, and so does a
  # question queued behind another, or behind what the person set aside —
  # answering it is not what frees the queue.
  defp detail(%{question_id: nil} = row), do: row.detail
  defp detail(%{asked: %{behind: behind}} = row) when is_integer(behind), do: row.detail
  defp detail(%{asked: %{waits: waits}} = row) when waits != nil, do: row.detail
  defp detail(row), do: Ink.yellow(row.detail)

  defp ticker(_row, 0, _tick), do: ""

  defp ticker(row, width, tick) do
    String.pad_trailing(if(ticking?(row), do: frame(tick), else: ""), width) <> "  "
  end

  defp frame(n), do: Enum.at(@frames, Integer.mod(n, length(@frames)))

  defp ticking?(row), do: row.status == "working" and is_nil(row.question_id)

  defp branch(branch), do: Text.plain(branch, @branch_max)

  defp more_line(0), do: nil
  defp more_line(more), do: Ink.dim("🐭 +#{more} more")

  # Why nothing is being delivered, where the person is already looking: what
  # they set aside, and the gate's reason (ADR-0058) — unless they are away, in
  # which case the gate is beside the point. The gate itself is untouched: this
  # is the queue saying it exists, in the one place a hold was otherwise silent.
  defp waiting_line(waiting, board) do
    parts =
      [
        if(waiting > 0, do: "#{waiting} waiting"),
        set_aside(board),
        gate(board)
      ]
      |> Enum.reject(&is_nil/1)

    if parts == [], do: nil, else: Ink.yellow("🐱 " <> Enum.join(parts, " · "))
  end

  defp set_aside(%{away?: true}), do: "away"
  defp set_aside(%{focus: focus}) when is_binary(focus), do: "focus: #{branch(focus)}"
  defp set_aside(_board), do: nil

  defp gate(%{away?: true}), do: nil
  defp gate(%{held: nil}), do: nil
  defp gate(%{held: held}), do: "gated: #{reason(held)}"

  defp reason(:typing), do: "your prompt box isn't empty"
  defp reason(:no_box), do: "your prompt box isn't on screen"
  defp reason(:mid_turn), do: "this session is mid-turn"
  defp reason(_unreachable), do: "your main session cannot be reached"

  # Its own word, under the waiting line: nobody can answer an orphan, so the
  # person is being told it is there, not asked to do anything about it. The
  # names say which work it was, so the number is something the person can
  # place rather than a nag.
  defp orphaned_line(0, _names), do: nil
  defp orphaned_line(orphaned, names), do: Ink.dim("🐱 #{orphaned} orphaned#{which(names)}")

  defp which([]), do: ""
  defp which(names), do: " (" <> Enum.join(fit(names), ", ") <> ")"

  # As many names as the budget holds, and the questions behind the rest summed
  # into `+n more` — so what the line shows always adds up to the count in front
  # of it. One name alone is shown however long it is: it is already cut to the
  # branch column, and an empty parenthesis would be worse than a wide one.
  defp fit(names) do
    # The widest the search can start is what the budget could hold if every
    # name were one character: `kept` names and the two characters of each
    # separator. Walking down from the number of orphans instead would re-join
    # the whole list once per name on a repo that has collected hundreds.
    total = min(length(names), div(@orphans_max + 2, 3))

    Enum.find_value(total..1//-1, fn kept ->
      shown = shown(names, kept)

      if String.length(Enum.join(shown, ", ")) <= @orphans_max, do: shown
    end) || shown(names, 1)
  end

  defp shown(names, kept) do
    {shown, dropped} = Enum.split(names, kept)

    Enum.map(shown, &named/1) ++ rest(dropped)
  end

  defp named(%{name: name, count: 1}), do: name
  defp named(%{name: name, count: count}), do: "#{name} ×#{count}"

  defp rest([]), do: []
  defp rest(dropped), do: ["+#{dropped |> Enum.map(& &1.count) |> Enum.sum()} more"]
end
