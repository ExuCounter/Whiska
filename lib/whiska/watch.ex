defmodule Whiska.Watch do
  @moduledoc """
  What every mouse in this house is doing, read once for every place that says
  it.

  The owl turns it into a line under each mouse's workspace in herdr's sidebar
  (`Whiska.Sidebar`, ADR-0082), and
  `whiska watch` prints the same lines on demand. This module holds the facts
  and no words: what each mouse is waiting on, what herdr says of its pane, and
  what it is doing, so two surfaces can never spell one fact two ways.

  A row is one live mouse: its question, if one is waiting on the person; how
  its pane stands with herdr; its topic — herdr's `terminal_title_stripped`, the
  short summary Claude Code keeps of what a session is working on — and its last
  action (`Whiska.Watch.Transcript`), which matters only when the mouse is not
  getting on with it: blocked at a dialog, or working and silent for longer than
  a tool call or the model explains.

  A dead mouse (ADR-0026) has no row: its worktree is gone. What it left behind
  is counted apart as orphaned, and never as waiting — an orphan has nowhere to
  reply, so calling it waiting tells the person to answer something they cannot.
  Nothing here acts; the board only reports.
  """

  alias Whiska.Delivery.Mode
  alias Whiska.Forge
  alias Whiska.Herdr
  alias Whiska.Layout
  alias Whiska.MergeRequests
  alias Whiska.Questions
  alias Whiska.Schema.MergeRequestRead
  alias Whiska.Schema.Mouse
  alias Whiska.Schema.Question
  alias Whiska.Shape
  alias Whiska.Storage
  alias Whiska.Watch.Text
  alias Whiska.Watch.Transcript

  @phrase_max 60
  @branch_max 24
  # How much of an orphan line the names may take; the rest is summed.
  @orphans_max 60

  # Ten minutes of nothing written to a transcript, on a mouse herdr says is
  # working and with no subagent out. A long test run, a long tool call or a long
  # think over a large context all stay quiet for minutes, and a line that read
  # `✖ stuck 2m` on healthy mice cried wolf (ADR-0082).
  @stuck_after 600

  @waiting ["open", "sent"]
  @orphaned "orphaned"

  @typedoc """
  How a mouse's pane stands with herdr: one agent pane in its worktree, none,
  more than one, or herdr not reachable to say.
  """
  @type pane_state :: :one | :none | :many | :unreachable

  @typedoc """
  One live mouse, as facts.

  `question_id` is the question this row stands for — one waiting on the
  person, or an answer its mouse never took (`not_taken?`). `asked` is set
  for a waiting one, and for a finished report that is still its branch's
  last word (`Whiska.Storage.finished/0`), which has no `question_id`: it waits
  on nobody (ADR-0009). `status` is herdr's word for the pane, `done` read as
  `idle`. `topic` and `doing` are read only when nothing about a question or a
  pane already decides what the row says. `in_flight?` is an idle pane whose
  last stop was passed over while its own background work runs (ADR-0052).
  """
  @type row :: %{
          mouse_id: String.t(),
          branch: String.t(),
          path: Path.t(),
          started_at: DateTime.t(),
          question_id: pos_integer() | nil,
          asked: asked() | nil,
          not_taken?: boolean(),
          held?: boolean(),
          sniff?: boolean(),
          pane: pane_state(),
          workspace_id: String.t() | nil,
          status: String.t() | nil,
          stuck?: boolean(),
          in_flight?: boolean(),
          silent_for: non_neg_integer() | nil,
          topic: String.t() | nil,
          doing: String.t() | nil,
          context: non_neg_integer() | nil,
          window: pos_integer(),
          picked_up_at: DateTime.t() | nil,
          stall: %{kind: String.t(), retry_at: DateTime.t() | nil} | nil,
          merge_request: merge_request() | nil
        }

  @typedoc """
  The merge request a mouse's branch waits on, by its forge's name for it, and
  what the owl last read of it, nil until a read of this link (ADR-0087).
  """
  @type merge_request :: %{label: String.t(), read: MergeRequestRead.t() | nil}

  @typedoc """
  What a row's question is waiting on: the person, since `sent_at` when it holds
  the delivery slot, or the question that does, `behind`. A finished report
  waits on nothing, so `finished?` is all it says.
  """
  @type asked :: %{
          sent_at: DateTime.t() | nil,
          behind: pos_integer() | nil,
          finished?: boolean(),
          waits: nil | :away | {:focus, String.t()}
        }

  @typedoc "One dead branch, and how many questions it left."
  @type orphan_name :: %{name: String.t(), count: pos_integer()}

  @typedoc "Why delivery is holding, when it has been holding long enough to say."
  @type held :: :typing | :no_box | :mid_turn | :unreachable | nil

  @typedoc """
  `waiting` is every answerable question no row carries; `orphaned` what
  nothing can act on any more, with `orphan_names` naming the branches those
  came off; `held` why the gate is not delivering; `away?` and `focus` what the
  person set aside — the focused mouse named by its branch.
  `unhoused_merge_requests` counts the merge requests still read for branches
  whose worktree is gone.
  """
  @type t :: %{
          rows: [row()],
          waiting: non_neg_integer(),
          orphaned: non_neg_integer(),
          orphan_names: [orphan_name()],
          held: held(),
          away?: boolean(),
          focus: String.t() | nil,
          unhoused_merge_requests: non_neg_integer()
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
  lists, so the two cannot disagree about what is running here.

  Options are `board/2`'s, plus `:away_path` for a mode read here rather than
  handed in.
  """
  @spec from_house(keyword()) :: t()
  def from_house(opts \\ []) do
    questions = Storage.questions() ++ Storage.orphaned_questions() ++ Storage.not_taken()

    board(
      Storage.alive_mice(),
      opts
      |> Keyword.put(:questions, questions)
      |> Keyword.put_new_lazy(:finished, &Storage.finished/0)
      |> Keyword.put_new_lazy(:picked_up, &Storage.picked_up/0)
      |> Keyword.put_new_lazy(:stalls, &Storage.stalls/0)
      |> Keyword.put_new_lazy(:merge_requests, &Storage.merge_request_reads/0)
      |> Keyword.put_new_lazy(:unhoused_merge_requests, fn ->
        Enum.count(MergeRequests.watched(), fn {mouse, _read} -> mouse.removed_at != nil end)
      end)
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
  `:finished`, the finished reports still their branch's last word, which a
  row stands for when its mouse has nothing waiting;
  `:panes`, herdr's answer in `Whiska.Herdr.list_panes/1` form; `:activity`,
  what a mouse is doing and how long it has been silent,
  `Whiska.Watch.Transcript.activity/1` unless a test pins it; `:waiting_on`, what
  a working mouse quiet for two minutes waits on,
  `Whiska.Watch.Transcript.waiting_on/1` unless a test pins it; `:passed_over`,
  whether an idle mouse with nothing to say had its last stop passed over,
  `Whiska.Watch.Transcript.passed_over/1` unless a test pins it; `:held`, why the
  gate is not delivering (ADR-0082); `:mode`, what the person set aside
  (`Whiska.Delivery.Mode.t/0`, nothing by default); `:picked_up`, when each
  branch the owl picked up was picked up, and `:stalls`, the API error each
  branch whose turn died on one is waiting out (ADR-0067); `:merge_requests`, the
  owl's last read of each mouse's merge request, and
  `:unhoused_merge_requests`, how many are read with no worktree (ADR-0087).
  """
  @spec board([Mouse.t()], keyword()) :: t()
  def board(mice, opts \\ []) do
    questions = Keyword.get(opts, :questions, [])
    panes = Keyword.get(opts, :panes, :no_socket)

    readers = %{
      activity: Keyword.get(opts, :activity, &Transcript.activity(&1.path)),
      waiting_on: Keyword.get(opts, :waiting_on, &Transcript.waiting_on(&1.path)),
      passed_over: Keyword.get(opts, :passed_over, &Transcript.passed_over(&1.path))
    }

    picked_up = %{at: Keyword.get(opts, :picked_up, %{}), stalls: Keyword.get(opts, :stalls, %{})}
    reads = Keyword.get(opts, :merge_requests, %{})
    mode = Keyword.get(opts, :mode, Mode.none())

    {orphaned, live} = Enum.split_with(questions, &(&1.status == @orphaned))

    by_mouse =
      opts
      |> Keyword.get(:finished, [])
      |> Enum.reduce(live |> Enum.reverse() |> Map.new(&{&1.mouse_id, &1}), fn report, rows ->
        Map.put_new(rows, report.mouse_id, report)
      end)

    focus = focus_name(mice, mode)
    context = %{slot: Mode.slot(live, mode), mode: mode, focus: focus}

    rows =
      mice
      |> Enum.filter(&is_nil(&1.died_at))
      |> Enum.map(&row(&1, by_mouse[&1.mouse_id], panes, readers, picked_up, context))
      |> Enum.map(&Map.put(&1, :merge_request, merge_request(&1, mice, reads)))

    %{
      rows: rows,
      waiting: live |> Enum.reject(&(Mode.waits(&1, mode) == :held)) |> uncovered(rows),
      orphaned: length(orphaned),
      orphan_names: orphan_names(orphaned),
      held: Keyword.get(opts, :held),
      away?: mode.away?,
      focus: focus,
      unhoused_merge_requests: Keyword.get(opts, :unhoused_merge_requests, 0)
    }
  end

  defp merge_request(row, mice, reads) do
    mouse = Enum.find(mice, &(&1.mouse_id == row.mouse_id))

    with %Mouse{merge_request_url: url} when is_binary(url) <- mouse,
         true <- Mouse.merge_request_waiting?(mouse),
         {:ok, ref} <- Forge.for_url(url) do
      read =
        case reads[mouse.mouse_id] do
          %MergeRequestRead{url: ^url} = read -> read
          _none_or_another_link -> nil
        end

      %{label: Forge.label(ref), read: read}
    else
      _ -> nil
    end
  end

  # The focused mouse by the name the person typed; the id names nothing to them.
  defp focus_name(_mice, %{focus: nil}), do: nil

  defp focus_name(mice, %{focus: mouse_id}) do
    case Enum.find(mice, &(&1.mouse_id == mouse_id)) do
      %Mouse{branch: branch} when is_binary(branch) -> branch
      _ -> mouse_id
    end
  end

  defp row(mouse, question, panes, readers, picked_up, context) do
    {pane_state, pane} = pane(mouse, panes)
    status = status(pane_state, pane)
    held? = match?(%DateTime{}, mouse.held_at)
    asked = if held?, do: nil, else: asked(question, context)
    question_id = question_id(question)

    base = %{
      mouse_id: mouse.mouse_id,
      branch: branch(mouse.branch || mouse.mouse_id),
      path: mouse.path,
      started_at: mouse.created_at,
      question_id: question_id,
      asked: asked,
      not_taken?: not held? and match?(%Question{status: "answered"}, question),
      held?: held?,
      sniff?: mouse.mode == "sniff",
      pane: pane_state,
      workspace_id: pane && Map.get(pane, :workspace_id),
      status: status,
      stuck?: false,
      in_flight?: false,
      silent_for: nil,
      topic: nil,
      doing: nil,
      context: nil,
      window: Shape.window(mouse.model),
      picked_up_at: if(question_id, do: nil, else: picked_up.at[mouse.mouse_id]),
      stall: if(question_id, do: nil, else: picked_up.stalls[mouse.mouse_id])
    }

    seen = readers.activity.(mouse)
    base = %{base | context: Map.get(seen, :context)}
    waiting_on = fn -> readers.waiting_on.(mouse) end

    cond do
      reads_activity?(base) -> with_activity(base, pane, seen, waiting_on)
      quiet?(base) -> after_stop(base, pane, seen, readers.passed_over.(mouse))
      true -> base
    end
  end

  # An idle pane with nothing to say for itself: no question, report or hold.
  # Its last stop may have been passed over while its own background work runs,
  # which herdr cannot see unless that work is a subagent (ADR-0052).
  defp quiet?(row) do
    row.status == "idle" and is_nil(row.question_id) and is_nil(row.asked) and not row.held? and
      row.pane == :one
  end

  defp after_stop(row, _pane, _seen, nil), do: row

  defp after_stop(row, pane, %{action: action, silent_for: silent_for}, passed_over) do
    %{
      row
      | in_flight?: passed_over == :in_flight,
        stuck?: passed_over == :abandoned,
        silent_for: silent_for,
        topic: topic(pane),
        doing: doing(action)
    }
  end

  # The transcript is read only for a mouse whose line is about what it is
  # doing: one herdr says is working or blocked, with nothing about a question,
  # a hold or its pane already saying more.
  defp reads_activity?(row) do
    row.status in ["working", "blocked"] and is_nil(row.question_id) and not row.held? and
      row.pane == :one
  end

  defp with_activity(row, pane, %{action: action, silent_for: silent_for}, waiting_on) do
    %{
      row
      | stuck?: stuck?(row.status, silent_for, waiting_on),
        silent_for: silent_for,
        topic: topic(pane),
        doing: doing(action)
    }
  end

  # An answer the board is handed is one its mouse never took (`from_house/1`),
  # which is the person's again, so its row stands for it like a question.
  defp question_id(%Question{status: status, id: id}) when status in @waiting, do: id
  defp question_id(%Question{status: "answered", id: id}), do: id
  defp question_id(_other), do: nil

  defp pane(mouse, {:ok, panes}) do
    case Enum.filter(panes, &agent_in?(&1, mouse.path)) do
      [] -> {:none, nil}
      [pane] -> {:one, pane}
      _many -> {:many, nil}
    end
  end

  defp pane(_mouse, _unreachable), do: {:unreachable, nil}

  defp agent_in?(pane, path),
    do: pane.agent != nil and is_binary(pane.cwd) and Layout.inside?(pane.cwd, path)

  # herdr's `done` is the same state as `idle` in a tab the person has not
  # looked at, which every mouse works in (ADR-0026 note in `Whiska.Owl.House`).
  defp status(:one, pane), do: said_status(pane.agent_status)
  defp status(_no_one_pane, _pane), do: nil

  defp said_status("done"), do: "idle"
  defp said_status(status), do: status

  # A question is waiting on the person only once it is the one they were told:
  # the sent one, or the next to go when nothing is sent. Everything else is
  # queued behind the slot's holder (ADR-0008), or waits behind what the person
  # set aside.
  defp asked(%Question{status: status} = question, context) when status in @waiting do
    %{
      sent_at: if(status == "sent", do: question.sent_at),
      behind: Questions.behind(question, context.slot),
      finished?: false,
      waits: waits(question, context)
    }
  end

  defp asked(%Question{kind: "done", status: "closed"}, _context) do
    %{
      sent_at: nil,
      behind: nil,
      finished?: true,
      waits: nil
    }
  end

  defp asked(_no_question, _context), do: nil

  # Only an open question waits behind the mode: a sent one was delivered, and
  # is waiting on the person whatever they set aside since.
  defp waits(%Question{status: "open"} = question, %{mode: mode, focus: focus}) do
    case Mode.waits(question, mode) do
      :away -> :away
      {:focus, _mouse_id} -> {:focus, branch(focus)}
      _ -> nil
    end
  end

  defp waits(_sent, _context), do: nil

  # What a mouse waits on is read only once it has been quiet long enough to be
  # stuck: it costs a longer read of the transcript.
  defp stuck?("blocked", _silent_for, _waiting_on), do: true

  defp stuck?("working", silent_for, waiting_on)
       when is_integer(silent_for) and silent_for >= @stuck_after do
    not waiting_on.().subagent?
  end

  defp stuck?(_quiet, _silent_for, _waiting_on), do: false

  defp doing({:tool, phrase}), do: phrase
  defp doing({:said, sentence}), do: ~s("#{sentence}")
  defp doing(nil), do: nil

  # The title is a mouse's own free text and arrives in some panes with the
  # agent's status glyph still on the front, so the topic starts at the title's
  # first letter or digit and `Whiska.Watch.Text` does the rest. A title with
  # neither is all glyph, and says nothing a line could show.
  defp topic(pane) do
    case pane |> Map.get(:title) |> glyphless() |> Text.plain(@phrase_max) do
      "" -> nil
      topic -> topic
    end
  end

  defp glyphless(title) when is_binary(title),
    do: String.replace(title, ~r/^[^\p{L}\p{N}]+/u, "")

  defp glyphless(_absent), do: ""

  # Every answerable question a row does not carry, so nothing waiting can go
  # unsaid: a question whose mouse record is gone. Orphans are counted on their
  # own, never here.
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
  # whole branch, and the cut comes after it, so a pair that shares the first 23
  # characters is not reported as one branch that left two questions.
  defp orphan_key(%Question{mouse: %Mouse{branch: branch}, id: id}) when is_binary(branch) do
    if branch(branch) == "", do: {:question, id}, else: {:branch, branch}
  end

  defp orphan_key(%Question{id: id}), do: {:question, id}

  defp said({:branch, branch}), do: branch(branch)
  defp said({:question, id}), do: "##{id}"

  defp branch(branch), do: Text.plain(branch, @branch_max)

  @doc """
  The orphans, as words: `2 orphaned (feat-gone ×2, #52)`, `nil` when there are
  none.

  As many names as the budget holds, and the questions behind the rest summed
  into `+n more` — so what the line shows always adds up to the count in front
  of it. One name alone is shown however long it is: it is already cut to a
  branch's width, and an empty parenthesis would be worse than a wide one.
  """
  @spec orphans(t()) :: String.t() | nil
  def orphans(%{orphaned: 0}), do: nil

  def orphans(%{orphaned: count, orphan_names: names}),
    do: "#{count} orphaned#{which(names)}"

  defp which([]), do: ""
  defp which(names), do: " (" <> Enum.join(fit(names), ", ") <> ")"

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
