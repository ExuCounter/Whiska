defmodule Whiska.Sidebar do
  @moduledoc """
  The lines herdr's sidebar draws for a house, as display tokens
  (ADR-0082). Under each mouse's workspace: its context size in one of
  `whiska_ctx`, `whiska_ctx_warn` or `whiska_ctx_full`, by how near its
  auto-compact window it is; `whiska`, its state, for a state herdr's own icon
  does not show; `whiska_topic`, what a working mouse is on; and `whiska_mr`,
  `whiska_ci`, `whiska_review`, the merge request its branch waits on, on one row
  (ADR-0087). Under the main checkout's workspace, `whiska`, `whiska_q` and
  `whiska_q2` say what is true of the whole repo.

  herdr colours a token only by its own text, so a colour is chosen by which
  token a value goes in, or by a rule on text only Whiska writes: every
  `whiska` line starts with a symbol nothing else does, and free text — a
  topic, a branch — never starts one.
  """

  alias Whiska.Context
  alias Whiska.MergeRequests
  alias Whiska.Mice
  alias Whiska.Shape
  alias Whiska.Watch

  @lines ["whiska", "whiska_q", "whiska_q2"]
  @sizes %{ok: "whiska_ctx", warn: "whiska_ctx_warn", full: "whiska_ctx_full"}
  @keys ["whiska_ctx", "whiska_ctx_warn", "whiska_ctx_full", "whiska", "whiska_topic"] ++
          tl(@lines) ++ ["whiska_mr", "whiska_ci", "whiska_review"]
  @rows [
    ["whiska_ctx", "whiska_ctx_warn", "whiska_ctx_full", "whiska", "whiska_topic"],
    ["whiska_q"],
    ["whiska_q2"],
    ["whiska_mr", "whiska_ci", "whiska_review"]
  ]

  # The colour key: the person's herdr config colours a line by its first
  # symbol, so every symbol a line can start with has a rule, in Solarized
  # shades the person is free to change. Plain working has none:
  # herdr's own icon says those.
  @colours [
    {"❓", "#2aa198"},
    {"⚠", "#dc322f"},
    {"✖", "#dc322f"},
    {"?", "#dc322f"},
    {"✓", "#3fb950"},
    {"⏳", "#b58900"},
    {"🎯", "#6c71c4"},
    {"💤", "#6c71c4"},
    {"⏸", "#6c71c4"},
    {"↩", "#268bd2"},
    {"↻", "#268bd2"},
    {"🔑", "#dc322f"},
    {"◐", "#268bd2"},
    {"○", "#e0891f"}
  ]

  # The merge request's pipeline and review, coloured by their own words.
  @pipeline_colours [{"✓", "#3fb950"}, {"◐", "#268bd2"}, {"✗", "#dc322f"}]
  @review_colours [
    {"ready", "#3fb950"},
    {"merged", "#3fb950"},
    {"closed", "#dc322f"},
    {"deleted", "#dc322f"},
    {"unread", "#93a1a1"}
  ]

  # The order of the brief: what wants the person most comes first, and a
  # finished mouse, which waits on nobody, last.
  @sent 1
  @next 2
  @stuck 4
  @queued 5
  @picked_up 6
  @working 7
  @lost 8
  @idle 9
  @focus 10
  @away 11
  @held 12
  @finished 13

  @type tokens :: %{optional(String.t()) => String.t()}

  @typedoc "One mouse's line: where it sorts, and the tokens herdr is given."
  @type line :: %{
          mouse_id: String.t(),
          branch: String.t(),
          rank: pos_integer(),
          sniff?: boolean(),
          under: String.t() | nil,
          tokens: tokens()
        }

  @doc "The token names Whiska reports, in the order they are drawn."
  @spec keys() :: [String.t()]
  def keys, do: @keys

  @doc """
  Each mouse's line, sorted by how much it wants the person; of mice that want
  the same, a build mouse comes before a sniff mouse, and the rest are left in
  the order they came. A mouse queued behind a question sits right under the
  mouse that holds it, queued mice in question order (ADR-0082).

  Options: `:now`, what ages are measured to.
  """
  @spec mice(Watch.t(), keyword()) :: [line()]
  def mice(board, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    rows = Enum.sort_by(board.rows, &if(&1.sniff?, do: 1, else: 0))

    rows
    |> Enum.map(&line(&1, now))
    |> Enum.sort_by(& &1.rank)
    |> under_holders(rows)
  end

  # A queued mouse leaves its own rank for the spot after the mouse whose
  # question it waits behind; one whose holder is not on the board stays put.
  defp under_holders(lines, rows) do
    # Only a mouse waiting on the person with nothing ahead of it holds a
    # question others queue behind, and only a mouse still drawn as queued
    # follows one: a held or away mouse keeps its own state's place.
    holder =
      for %{question_id: id, asked: %{behind: nil}} = row <- rows,
          is_integer(id),
          into: %{},
          do: {id, row.mouse_id}

    ranks = Map.new(lines, &{&1.mouse_id, &1.rank})

    queued =
      for %{asked: %{behind: id}} = row <- rows,
          Map.has_key?(holder, id),
          ranks[row.mouse_id] == @queued,
          into: %{} do
        {row.mouse_id, {holder[id], row.question_id}}
      end

    following =
      lines
      |> Enum.filter(&Map.has_key?(queued, &1.mouse_id))
      |> Enum.sort_by(&elem(queued[&1.mouse_id], 1))
      |> Enum.group_by(
        &elem(queued[&1.mouse_id], 0),
        &%{&1 | under: elem(queued[&1.mouse_id], 0)}
      )

    lines
    |> Enum.reject(&Map.has_key?(queued, &1.mouse_id))
    |> Enum.flat_map(&[&1 | Map.get(following, &1.mouse_id, [])])
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

  @doc "The rank of `○ idle`, the state a new mouse may take without a re-sort."
  @spec idle_rank() :: pos_integer()
  def idle_rank, do: @idle

  @doc """
  Where this mouse's state sorts: lines with the same rank want the person the
  same, so the house re-sorts when a mouse's rank changes (ADR-0082).
  """
  @spec rank(line()) :: pos_integer()
  def rank(%{rank: rank}), do: rank

  defp line(row, now) do
    {rank, said, topic} = state(row, now)

    %{
      mouse_id: row.mouse_id,
      branch: row.branch,
      rank: rank,
      sniff?: row.sniff?,
      under: nil,
      tokens:
        [{"whiska", said}, {"whiska_topic", topic}, size(rank, row)]
        |> Enum.reject(&(elem(&1, 1) in [nil, ""]))
        |> Map.new()
        |> Map.merge(merge_request(Map.get(row, :merge_request), now))
    }
  end

  # A line that says the pane is lost has no size: it is not about the mouse.
  defp size(@lost, _row), do: {"whiska_ctx", nil}

  defp size(_rank, %{context: tokens} = row) when is_integer(tokens) do
    {@sizes[Context.band(tokens, Map.get(row, :window) || Shape.window(nil))],
     Context.size(tokens)}
  end

  defp size(_rank, _row), do: {"whiska_ctx", nil}

  # The request's name, its pipeline, and what its review says, each a token of
  # its own so each takes its own colour; one with nothing to say is left out.
  defp merge_request(nil, _now), do: %{}

  defp merge_request(%{label: label, read: read}, now) do
    {pipeline, review} = read(read, now)

    [{"whiska_mr", "⎇ #{label}"}, {"whiska_ci", pipeline}, {"whiska_review", review}]
    |> Enum.reject(&is_nil(elem(&1, 1)))
    |> Map.new()
  end

  defp read(nil, _now), do: {nil, nil}
  defp read(%{state: "merged"}, _now), do: {nil, "merged"}
  defp read(%{state: "closed"}, _now), do: {nil, "closed"}
  defp read(%{state: "gone"}, _now), do: {nil, "deleted"}

  defp read(%{unread_since: %DateTime{} = since} = read, now) do
    if MergeRequests.unread?(read, now),
      do: {nil, "unread #{age(since, now)}"},
      else: read(%{read | unread_since: nil}, now)
  end

  defp read(%{state: nil}, _now), do: {nil, nil}
  defp read(read, _now), do: {pipeline(read.pipeline), review(read)}

  defp pipeline("failed"), do: "✗"
  defp pipeline("running"), do: "◐"
  defp pipeline("passed"), do: "✓"
  defp pipeline(_none), do: nil

  defp review(%{ready: true}), do: "ready"
  defp review(%{threads_open: 1}), do: "1 open"
  defp review(%{threads_open: open}) when open > 1, do: "#{open} open"
  defp review(_quiet), do: nil

  # First match wins: a hold is the person's own word on the mouse, a question
  # is what they are asked, and only then does herdr's view of the pane, and
  # what the mouse is doing, get a say. Working and idle say nothing of their
  # own: herdr's icon beside the workspace already does.
  defp state(%{held?: true}, _now), do: {@held, "⏸ held", nil}

  defp state(%{not_taken?: true}, _now), do: {@next, "❓ answer not taken", nil}

  defp state(%{asked: %{} = asked}, now), do: asked(asked, now)

  defp state(%{pane: :none}, _now), do: {@lost, "✖ no pane", nil}
  defp state(%{pane: :many}, _now), do: {@lost, "⚠ many panes", nil}
  defp state(%{pane: :unreachable}, _now), do: {@lost, "? herdr can't say", nil}
  defp state(%{status: "unknown"}, _now), do: {@lost, "? herdr can't say", nil}

  # A turn that died on an API error, waiting for its next pickup (ADR-0067).
  # While the pickup's own turn runs, the line says it was picked up instead.
  defp state(%{stall: %{} = stall, status: status}, now) when status != "working",
    do: stalled(stall, now)

  defp state(%{stuck?: true} = row, _now), do: {@stuck, stuck(row.silent_for), nil}

  defp state(%{picked_up_at: %DateTime{} = at}, now),
    do: {@picked_up, "↩ picked up #{age(at, now)} ago", nil}

  defp state(%{status: "working"} = row, _now),
    do: {@working, nil, row.topic || row.doing || "working"}

  # herdr's icon calls this pane idle, so the line says what it cannot.
  defp state(%{in_flight?: true} = row, _now),
    do: {@working, "◐ background", row.topic || row.doing}

  defp state(_idle, _now), do: {@idle, "○ idle", nil}

  defp asked(%{waits: :away}, _now), do: {@away, "💤 waits: away", nil}

  defp asked(%{waits: {:focus, branch}}, _now),
    do: {@focus, "🎯 waits: focus on #{branch}", nil}

  defp asked(%{behind: behind}, _now) when is_integer(behind), do: {@queued, "⏳ queued", nil}

  defp asked(%{finished?: true}, _now), do: {@finished, "✓ finished", nil}

  defp asked(%{sent_at: %DateTime{} = at}, now),
    do: {@sent, "❓ waiting on you · #{age(at, now)}", nil}

  defp asked(_asked, _now), do: {@next, "❓ waiting on you", nil}

  defp stalled(%{kind: "authentication_failed"}, _now),
    do: {@stuck, "🔑 login expired · run /login", nil}

  defp stalled(%{retry_at: nil}, _now), do: {@stuck, "✖ API error", nil}

  defp stalled(%{kind: "rate_limit", retry_at: at}, now),
    do: {@picked_up, "⏳ limit · resets #{clock(at, now)}", nil}

  defp stalled(%{retry_at: at}, now) do
    case DateTime.diff(at, now) do
      due when due <= 0 -> {@picked_up, "↻ API error · retrying", nil}
      due -> {@picked_up, "↻ API error · retry in #{minutes(due)}", nil}
    end
  end

  # The person's own clock: the hour alone today, the day too when it is not.
  defp clock(at, now) do
    at = local(at)
    time = Calendar.strftime(at, "%H:%M")

    if NaiveDateTime.to_date(at) == NaiveDateTime.to_date(local(now)),
      do: time,
      else: Calendar.strftime(at, "%b %-d ") <> time
  end

  defp local(%DateTime{} = at) do
    at
    |> DateTime.to_naive()
    |> NaiveDateTime.to_erl()
    |> :calendar.universal_time_to_local_time()
    |> NaiveDateTime.from_erl!()
  end

  defp stuck(nil), do: "✖ stuck"
  defp stuck(silent_for), do: "✖ stuck #{minutes(silent_for)}"

  defp age(at, now), do: minutes(DateTime.diff(now, at))

  # A sidebar line is re-sent when its words change, so it counts minutes: a
  # line that ticked every second would be sent every second.
  defp minutes(seconds) when seconds < 60, do: "<1m"
  defp minutes(seconds) when seconds < 3600, do: "#{div(seconds, 60)}m"
  defp minutes(seconds), do: Mice.format_uptime(seconds)

  defp tokens(lines) do
    lines
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.zip(@lines)
    |> Map.new(fn {text, key} -> {key, text} end)
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
      orphaned(Watch.orphans(board)),
      unhoused(Map.get(board, :unhoused_merge_requests, 0))
    ])
  end

  defp unhoused(0), do: nil
  defp unhoused(1), do: "⎇ 1 merge request, no worktree"
  defp unhoused(n), do: "⎇ #{n} merge requests, no worktree"

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

  # ADR-0082's reasons in a sidebar's width; `whiska doctor` keeps the long ones.
  defp reason(:typing), do: "you're typing"
  defp reason(:no_box), do: "no prompt box"
  defp reason(:mid_turn), do: "main is mid-turn"
  defp reason(_unreachable), do: "main unreachable"

  defp carried_by(rows, no_workspace) do
    Enum.count(rows, &(MapSet.member?(no_workspace, &1.mouse_id) and question?(&1)))
  end

  defp question?(%{asked: %{finished?: true}}), do: false
  defp question?(%{asked: %{}}), do: true
  defp question?(%{not_taken?: true}), do: true
  defp question?(_row), do: false

  defp off_sidebar(0), do: nil
  defp off_sidebar(n), do: "❓ #{n} more: whiska questions"

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

  # The rows `snippet/0` draws, each joined the way herdr joins a row's tokens.
  defp said(tokens) do
    for row <- @rows,
        words = for(key <- row, Map.has_key?(tokens, key), do: tokens[key]),
        words != [],
        do: Enum.join(words, " · ")
  end

  @doc """
  The rows for the person's herdr config that draw every token in `keys/0`,
  coloured by which token a value is in or by its first symbol. Whiska never
  writes that file (ADR-0048); the doctor prints this.
  """
  @spec snippet() :: String.t()
  def snippet do
    """
    [ui.sidebar.spaces]
    row_gap = 0
    rows = [
      ["state_icon", { token = "workspace", fg = "#586e75", dim = false }],
      ["branch", "git_status"],
      [{ token = "$whiska_ctx", fg = "#93a1a1" }, { token = "$whiska_ctx_warn", fg = "#b58900" }, { token = "$whiska_ctx_full", fg = "#dc322f" }, { token = "$whiska", fg = "#657b83", dim = false, rules = [
    #{rules(@colours)}
      ] }, { token = "$whiska_topic", fg = "#657b83" }],
      [{ token = "$whiska_q", fg = "#93a1a1" }],
      [{ token = "$whiska_q2", fg = "#93a1a1" }],
      [{ token = "$whiska_mr", fg = "#93a1a1" }, { token = "$whiska_ci", fg = "#93a1a1", rules = [
    #{rules(@pipeline_colours)}
      ] }, { token = "$whiska_review", fg = "#b58900", rules = [
    #{rules(@review_colours)}
      ] }],
    ]
    """
  end

  defp rules(colours) do
    Enum.map_join(colours, "\n", fn {start, fg} ->
      ~s(    { starts_with = "#{start}", fg = "#{fg}" },)
    end)
  end

  @doc "Every start of a token's text that `snippet/0` colours by a rule."
  @spec symbols() :: [String.t()]
  def symbols, do: Enum.map(@colours ++ @pipeline_colours ++ @review_colours, &elem(&1, 0))
end
