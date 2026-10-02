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

  alias Whiska.Herdr
  alias Whiska.Layout
  alias Whiska.Question.Marker
  alias Whiska.Schema.Mouse
  alias Whiska.Schema.Question
  alias Whiska.Storage
  alias Whiska.Watch.Text
  alias Whiska.Watch.Transcript

  @board_max 5
  @phrase_max 60
  @branch_max 24

  # The ticker: proof the board is being redrawn, on the rows where a still
  # picture and a frozen one look the same. One frame per snapshot the owl
  # writes, so at ADR-0051's two seconds the cycle takes six.
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
          detail: String.t()
        }

  @typedoc """
  `more` is how many live mice the cap left off; `waiting` what no row covers
  and the person can still answer; `orphaned` what nothing can act on any more.
  """
  @type t :: %{
          rows: [row()],
          more: non_neg_integer(),
          waiting: non_neg_integer(),
          orphaned: non_neg_integer()
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

  Options are `board/2`'s.
  """
  @spec from_house(keyword()) :: t()
  def from_house(opts \\ []) do
    questions = Storage.questions() ++ Storage.orphaned_questions()

    board(Storage.alive_mice(), Keyword.put(opts, :questions, questions))
  end

  defp ask_herdr(nil), do: :no_socket
  defp ask_herdr(socket), do: Herdr.impl().list_panes(socket)

  @doc """
  The board for a house's mice.

  Options: `:questions`, its waiting and orphaned questions, counted apart;
  `:panes`, herdr's answer in `Whiska.Mice.panes/0` form; `:activity`, what a
  mouse is doing and how long it has been silent,
  `Whiska.Watch.Transcript.activity/1` unless a test pins it.
  """
  @spec board([Mouse.t()], keyword()) :: t()
  def board(mice, opts \\ []) do
    questions = Keyword.get(opts, :questions, [])
    panes = Keyword.get(opts, :panes, :no_socket)
    activity = Keyword.get(opts, :activity, &Transcript.activity(&1.path))

    {orphaned, live} = Enum.split_with(questions, &(&1.status == @orphaned))
    by_mouse = live |> Enum.reverse() |> Map.new(&{&1.mouse_id, &1})

    {rows, more} =
      mice
      |> Enum.filter(&is_nil(&1.died_at))
      |> Enum.map(&row(&1, by_mouse[&1.mouse_id], panes, activity))
      |> Enum.sort_by(&rank/1)
      |> cap()

    %{rows: rows, more: more, waiting: uncovered(live, rows), orphaned: length(orphaned)}
  end

  defp row(mouse, question, panes, activity) do
    pane = pane(mouse, panes)
    status = status(pane)

    %{
      mouse_id: mouse.mouse_id,
      question_id: question_id(question),
      branch: mouse.branch || mouse.mouse_id,
      status: status,
      detail: detail(question, pane, status, fn -> activity.(mouse) end)
    }
  end

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

  defp detail(%Question{status: status} = question, _pane, _status, _activity)
       when status in @waiting do
    case Text.plain(Marker.pointer(question.text), @phrase_max) do
      "" -> "waiting on you · ##{question.id}"
      pointer -> ~s(waiting on you · ##{question.id} · "#{pointer}")
    end
  end

  defp detail(_question, pane, status, activity) do
    %{action: action, silent_for: silent_for} = activity.()
    topic = topic(pane)
    doing = doing(action)

    if stuck?(status, silent_for),
      do: doing || topic || "",
      else: topic || doing || ""
  end

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

  def render(%{rows: [], more: 0, waiting: 0, orphaned: 0}, _opts), do: ""

  def render(%{rows: rows, more: more, waiting: waiting, orphaned: orphaned}, opts) do
    tick = Keyword.get(opts, :frame)
    widths = widths(rows, tick)

    (Enum.map(rows, &line(&1, widths, tick)) ++
       [more_line(more), waiting_line(waiting), orphaned_line(orphaned)])
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp widths(rows, tick) do
    %{
      branch: width(rows, &String.length(branch(&1.branch))),
      status: width(rows, &String.length(&1.status)),
      # The column is as wide as the longest frame and is there whether or not
      # anything is working, so a row's detail sits in the same place while the
      # dots grow, and stays there when the last working mouse stops.
      ticker: if(is_integer(tick), do: @ticker_width, else: 0)
    }
  end

  defp width([], _of), do: 0
  defp width(rows, of), do: rows |> Enum.map(of) |> Enum.max()

  defp line(row, widths, tick) do
    text =
      "🐭 " <>
        String.pad_trailing(branch(row.branch), widths.branch) <>
        "  " <>
        String.pad_trailing(row.status, widths.status) <>
        "  " <> ticker(row, widths.ticker, tick) <> row.detail

    String.trim_trailing(text)
  end

  defp ticker(_row, 0, _tick), do: ""

  defp ticker(row, width, tick) do
    String.pad_trailing(if(ticking?(row), do: frame(tick), else: ""), width) <> "  "
  end

  defp frame(n), do: Enum.at(@frames, Integer.mod(n, length(@frames)))

  defp ticking?(row), do: row.status == "working" and is_nil(row.question_id)

  defp branch(branch), do: Text.plain(branch, @branch_max)

  defp more_line(0), do: nil
  defp more_line(more), do: "🐭 +#{more} more"

  defp waiting_line(0), do: nil
  defp waiting_line(waiting), do: "🐱 #{waiting} waiting"

  # Its own word, under the waiting line: nobody can answer an orphan, so the
  # person is being told it is there, not asked to do anything about it.
  defp orphaned_line(0), do: nil
  defp orphaned_line(orphaned), do: "🐱 #{orphaned} orphaned"
end
