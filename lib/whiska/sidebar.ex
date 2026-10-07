defmodule Whiska.Sidebar do
  @moduledoc """
  The lines herdr's sidebar draws for a house, as display tokens
  (ADR-next-a-mouses-state-is-a-line-in-herdrs-sidebar): under each mouse's
  workspace, `whiska` is its state and `whiska_q`, `whiska_q2` the question it
  carries, wrapped; under the main checkout's workspace, what is true of the
  whole repo.

  Every `whiska` line starts with a symbol Whiska chooses and nothing else
  does, so the person's herdr config can colour a line by its first symbol
  (`snippet/0`) and free text after it — a topic, a branch — can never pass for
  another state. herdr colours a token only by its own text, so the symbol is
  the state.
  """

  alias Whiska.Mice
  alias Whiska.Watch

  @keys ["whiska", "whiska_q", "whiska_q2"]
  @width 31
  @frames ["◐", "◓", "◑", "◒"]

  # The colour key: the person's herdr config colours a line by its first
  # symbol, so every symbol a line can start with has a rule, in Solarized
  # shades the person is free to change.
  @colours [
    {"🐭", "#cb4b16"},
    {"⚠", "#dc322f"},
    {"✖", "#dc322f"},
    {"?", "#dc322f"},
    {"✅", "#859900"},
    {"⏳", "#b58900"},
    {"🎯", "#6c71c4"},
    {"💤", "#6c71c4"},
    {"⏸", "#6c71c4"},
    {"↩", "#268bd2"},
    {"◐", "#268bd2"},
    {"◓", "#268bd2"},
    {"◑", "#268bd2"},
    {"◒", "#268bd2"}
  ]

  # The order of the brief: what wants the person most comes first.
  @sent 1
  @next 2
  @finished 3
  @stuck 4
  @queued 5
  @finished_queued 6
  @focus 7
  @away 8
  @held 9
  @picked_up 10
  @working 11
  @lost 12
  @idle 13

  @type tokens :: %{optional(String.t()) => String.t()}

  @typedoc "One mouse's line: where it sorts, and the tokens herdr is given."
  @type line :: %{
          mouse_id: String.t(),
          branch: String.t(),
          rank: pos_integer(),
          tokens: tokens()
        }

  @doc "The token names Whiska reports, in the order they are drawn."
  @spec keys() :: [String.t()]
  def keys, do: @keys

  @doc """
  Each mouse's line, sorted by how much it wants the person; mice that want the
  same are left in the order they came.

  Options: `:now`, what ages are measured to; `:frame`, the working spinner's
  frame, counted in writes so it moves only when a line is actually sent.
  """
  @spec mice(Watch.t(), keyword()) :: [line()]
  def mice(board, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    frame = Keyword.get(opts, :frame, 0)

    board.rows
    |> Enum.map(&line(&1, now, frame))
    |> Enum.sort_by(& &1.rank)
  end

  @doc """
  Which workspace each mouse's line goes under: the one open on its worktree,
  or else one opened on no checkout that holds its agent pane — never one
  opened on another checkout, and never `main_workspace`, which carries the
  repo's own line. A workspace two mice would share goes to the one that wants
  the person more; a mouse left without one is left out.
  """
  @spec place(Watch.t(), [Whiska.Herdr.workspace()], String.t() | nil) ::
          %{String.t() => String.t()}
  def place(board, workspaces, main_workspace \\ nil) do
    by_path =
      for ws <- workspaces,
          is_binary(ws.path),
          into: %{},
          do: {Path.expand(ws.path), ws.workspace_id}

    checkout_less =
      for ws <- workspaces, is_nil(ws.path), into: MapSet.new(), do: ws.workspace_id

    rows = Map.new(board.rows, &{&1.mouse_id, &1})

    board
    |> mice()
    |> Enum.reduce(%{}, fn line, placed ->
      row = rows[line.mouse_id]
      ws = by_path[Path.expand(row.path)] || pane_workspace(row.workspace_id, checkout_less)

      if ws == nil or ws == main_workspace or ws in Map.values(placed),
        do: placed,
        else: Map.put(placed, row.mouse_id, ws)
    end)
  end

  defp pane_workspace(nil, _checkout_less), do: nil
  defp pane_workspace(ws, checkout_less), do: if(MapSet.member?(checkout_less, ws), do: ws)

  @doc "Whether this mouse is waiting on the person or has finished for them."
  @spec needs_you?(line()) :: boolean()
  def needs_you?(%{rank: rank}), do: rank <= @finished

  defp line(row, now, frame) do
    {rank, said, carried} = state(row, now, frame)

    %{
      mouse_id: row.mouse_id,
      branch: row.branch,
      rank: rank,
      tokens: tokens([said | wrap(carried)])
    }
  end

  defp tokens(lines) do
    lines
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.zip(@keys)
    |> Map.new(fn {text, key} -> {key, text} end)
  end

  # First match wins: a hold is the person's own word on the mouse, a question
  # is what they are asked, and only then does herdr's view of the pane, and
  # what the mouse is doing, get a say.
  defp state(%{held?: true, question_id: id}, _now, _frame) when is_integer(id),
    do: {@held, "⏸ ##{id} · held", nil}

  defp state(%{held?: true}, _now, _frame), do: {@held, "⏸ held", nil}

  defp state(%{not_taken?: true, question_id: id}, _now, _frame),
    do: {@next, "🐭 ##{id} · answer not taken", nil}

  defp state(%{asked: %{} = asked, question_id: id}, now, _frame), do: asked(id, asked, now)

  defp state(%{pane: :none}, _now, _frame), do: {@lost, "✖ no pane", nil}
  defp state(%{pane: :many}, _now, _frame), do: {@lost, "⚠ many panes", nil}
  defp state(%{pane: :unreachable}, _now, _frame), do: {@lost, "? herdr can't say", nil}
  defp state(%{status: "unknown"}, _now, _frame), do: {@lost, "? herdr can't say", nil}

  defp state(%{stuck?: true} = row, _now, _frame),
    do: {@stuck, stuck(row.silent_for), row.doing || row.topic}

  defp state(%{picked_up_at: %DateTime{} = at}, now, _frame),
    do: {@picked_up, "↩ picked up #{age(at, now)} ago", nil}

  defp state(%{status: "working"} = row, _now, frame),
    do: {@working, "#{spinner(frame)} #{row.topic || row.doing || "working"}", nil}

  defp state(_idle, _now, _frame), do: {@idle, nil, nil}

  defp asked(id, %{waits: :away}, _now), do: {@away, "💤 ##{id} · waits: away", nil}

  defp asked(id, %{waits: {:focus, branch}}, _now),
    do: {@focus, "🎯 ##{id} · waits: focus on #{branch}", nil}

  defp asked(_id, %{behind: behind, finished?: true}, _now) when is_integer(behind),
    do: {@finished_queued, "✅ finished · queued behind ##{behind}", nil}

  defp asked(_id, %{behind: behind} = asked, _now) when is_integer(behind),
    do: {@queued, "⏳ queued behind ##{behind}", asked.pointer}

  defp asked(id, %{finished?: true} = asked, _now),
    do: {@finished, "✅ ##{id} · finished", asked.pointer}

  defp asked(id, %{sent_at: %DateTime{} = at} = asked, now),
    do: {@sent, "🐭 ##{id} · waiting on you · #{age(at, now)}", asked.pointer}

  defp asked(id, asked, _now), do: {@next, "🐭 ##{id} · waiting on you", asked.pointer}

  defp stuck(nil), do: "⚠ stuck"
  defp stuck(silent_for), do: "⚠ stuck #{minutes(silent_for)}"

  defp spinner(frame), do: Enum.at(@frames, Integer.mod(frame, length(@frames)))

  defp age(at, now), do: minutes(DateTime.diff(now, at))

  # A sidebar line is re-sent when its words change, so it counts minutes: a
  # line that ticked every second would be sent every second.
  defp minutes(seconds) when seconds < 60, do: "<1m"
  defp minutes(seconds) when seconds < 3600, do: "#{div(seconds, 60)}m"
  defp minutes(seconds), do: Mice.format_uptime(seconds)

  @doc """
  `text` on at most two lines of 31 characters, broken between words; a word
  longer than a line is broken inside it, and whatever does not fit ends the
  second line with `…`.
  """
  @spec wrap(String.t() | nil) :: [String.t()]
  def wrap(nil), do: []

  def wrap(text) do
    text
    |> String.split(" ", trim: true)
    |> Enum.flat_map(&chunks/1)
    |> fill([])
    |> cut()
  end

  defp chunks(word) do
    word |> String.graphemes() |> Enum.chunk_every(@width) |> Enum.map(&Enum.join/1)
  end

  defp fill([], lines), do: Enum.reverse(lines)
  defp fill([word | words], []), do: fill(words, [word])

  defp fill([word | words], [line | done]) do
    if String.length(line) + 1 + String.length(word) <= @width,
      do: fill(words, [line <> " " <> word | done]),
      else: fill(words, [word, line | done])
  end

  defp cut([first, second, _ | _]), do: [first, ellipsis(second)]
  defp cut(lines), do: lines

  defp ellipsis(line) do
    if String.length(line) < @width,
      do: line <> "…",
      else: String.slice(line, 0, @width - 1) <> "…"
  end

  @doc """
  The main checkout's line: the three most urgent things true of the whole
  repo, one to a token, each short enough that the command it names is never
  cut off. Empty when nothing is.

  Options: `:main_pane?`, whether a main session is recorded; `:no_workspace`, the
  mice that have no workspace for a line of their own.
  """
  @spec house(Watch.t(), keyword()) :: tokens()
  def house(board, opts \\ []) do
    no_workspace = Keyword.get(opts, :no_workspace, MapSet.new())

    tokens([
      no_main_session(board, Keyword.get(opts, :main_pane?, true)),
      gated(board),
      off_sidebar(board.waiting + carried_by(board.rows, no_workspace)),
      orphaned(Watch.orphans(board))
    ])
  end

  # Said only while something could need delivering: a repo with nothing
  # running and nothing waiting is fine without one.
  defp no_main_session(%{rows: [], waiting: 0}, _main_pane?), do: nil
  defp no_main_session(_board, true), do: nil
  defp no_main_session(_board, false), do: "✖ no main session: whiska start"

  # Away is the person saying they are not there, so why the gate holds is
  # beside the point.
  defp gated(%{away?: true}), do: nil
  defp gated(%{held: nil}), do: nil
  defp gated(%{held: held}), do: "⏳ gated: #{reason(held)}"

  # ADR-0058's reasons in a sidebar's width; `whiska doctor` keeps the long ones.
  defp reason(:typing), do: "you're typing"
  defp reason(:no_box), do: "no prompt box"
  defp reason(:mid_turn), do: "main is mid-turn"
  defp reason(_unreachable), do: "main unreachable"

  defp carried_by(rows, no_workspace) do
    Enum.count(rows, &(MapSet.member?(no_workspace, &1.mouse_id) and question?(&1)))
  end

  defp question?(%{asked: %{}}), do: true
  defp question?(%{not_taken?: true}), do: true
  defp question?(_row), do: false

  defp off_sidebar(0), do: nil
  defp off_sidebar(n), do: "🐭 #{n} more: whiska questions"

  defp orphaned(nil), do: nil
  defp orphaned(said), do: "◌ " <> said

  @doc """
  The lines as `whiska watch` prints them: the main checkout's first, then each
  mouse under its branch, in sidebar order.
  """
  @spec render(tokens(), [line()]) :: String.t()
  def render(house, lines) do
    [lines_of(house) | Enum.map(lines, &mouse_block/1)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp mouse_block(%{branch: branch, tokens: tokens}) do
    Enum.join([branch | Enum.map(said(tokens), &("  " <> &1))], "\n")
  end

  defp lines_of(tokens), do: tokens |> said() |> Enum.join("\n")

  defp said(tokens), do: for(key <- @keys, Map.has_key?(tokens, key), do: tokens[key])

  @doc """
  The rows for the person's herdr config that draw these lines, coloured by
  each line's first symbol. Whiska never writes that file (ADR-0048); the
  doctor prints this.
  """
  @spec snippet() :: String.t()
  def snippet do
    rules =
      Enum.map_join(@colours, "\n", fn {symbol, fg} ->
        ~s(    { starts_with = "#{symbol}", fg = "#{fg}" },)
      end)

    """
    [ui.sidebar.spaces]
    rows = [
      ["state_icon", { token = "workspace", fg = "#586e75", dim = false }],
      ["branch", "git_status"],
      [{ token = "$whiska", fg = "#657b83", dim = false, rules = [
    #{rules}
      ] }],
      [{ token = "$whiska_q", fg = "#93a1a1" }],
      [{ token = "$whiska_q2", fg = "#93a1a1" }],
    ]
    """
  end

  @doc "Every symbol a line can start with that `snippet/0` colours."
  @spec symbols() :: [String.t()]
  def symbols, do: Enum.map(@colours, &elem(&1, 0))
end
