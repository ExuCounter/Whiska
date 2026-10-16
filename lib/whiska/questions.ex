defmodule Whiska.Questions do
  @moduledoc """
  What is waiting on the person in one house — asked once, shown three ways.

  `whiska questions` and the project statusline both answer "how many questions
  are open here". The spec has the statusline read the underlying data directly
  rather than shelling out to the command, so the reading lives here and each
  caller only renders: `render/1` for the listing, `render_full/1` for the same
  thing at length (`whiska questions --full`), and `statusline/1` for the one
  segment the statusline appends (ADR-0048). A statusline that disagreed with
  the listing about what is waiting would be worse than either alone.

  Three sources, each asked for what only it knows: the house's open and sent
  questions (`Whiska.Storage.questions/0`), its orphaned ones — shown apart and
  never counted, since there is nowhere to reply (ADR-0036) — and the doorstep,
  whose uncollected entries the database cannot see at all.

  Nothing here writes. A house Whiska has never opened is left unopened; the
  doorstep is read, never collected — collection is the owl's job (ADR-0036).
  """

  alias Whiska.Delivery.Mode
  alias Whiska.Doorstep
  alias Whiska.Question.Marker
  alias Whiska.Report
  alias Whiska.Review
  alias Whiska.Schema.Mouse
  alias Whiska.Schema.Question
  alias Whiska.Storage

  # An entry sitting uncollected longer than the owl's backstop is evidence the
  # owl is not collecting. Until the owl answers a socket (ADR-0048), age is the
  # only signal there is; anything younger may just be the normal race between
  # the two Stop hooks (ADR-0036).
  @backstop_s 60

  @doc """
  How long an entry may sit uncollected before it is evidence, not a race.

  Shared so `Whiska.Statusline` reads the owl's collecting the same way this
  does; two numbers could disagree about whether the owl is up.
  """
  @spec backstop_s() :: pos_integer()
  def backstop_s, do: @backstop_s

  # One listing line has room for a pointer; one statusline segment for less.
  @pointer_max 80
  @segment_max 60

  @type summary :: %{
          open: [Question.t()],
          orphaned: [Question.t()],
          not_taken: [Question.t()],
          doorstep: non_neg_integer(),
          doorstep_stale: boolean(),
          mode: Mode.t(),
          focus: String.t() | nil
        }

  @doc """
  Everything waiting in the house whose main checkout this is.

  `open` (open and sent), `orphaned` and `not_taken` (answers the owl gave up
  ringing for) come from the database; `doorstep`
  counts entries the owl has not collected yet, a finished report's left out,
  and `doorstep_stale` says whether any, a finished report's included, has
  waited past the backstop; `mode` is what the person set
  aside, with `focus` the focused mouse's branch. A house with no database yet
  is simply empty — it is not created. Options: `:away_path`.
  """
  @spec summary(Path.t(), keyword()) :: {:ok, summary()} | {:error, term()}
  def summary(main_checkout, opts \\ []) do
    with {:ok, open, orphaned, not_taken, mode, focus} <- read_house(main_checkout, opts) do
      waiting = Doorstep.waiting(main_checkout)
      now = DateTime.utc_now()

      stale =
        Enum.any?(waiting, fn {_file, entry} ->
          DateTime.diff(now, entry.stamped_at, :second) > @backstop_s
        end)

      {:ok,
       %{
         open: open,
         orphaned: orphaned,
         not_taken: not_taken,
         doorstep: Enum.count(waiting, fn {_file, e} -> Marker.classify(e.text) != "done" end),
         doorstep_stale: stale,
         mode: mode,
         focus: focus
       }}
    end
  end

  defp read_house(main_checkout, opts) do
    away_path = Keyword.get_lazy(opts, :away_path, &Mode.away_path/0)

    if File.exists?(Storage.database_path(main_checkout)) do
      case Storage.open(main_checkout) do
        {:ok, handle} ->
          try do
            mode = Mode.read(away_path: away_path)

            {:ok, Storage.questions(), Storage.orphaned_questions(), Storage.not_taken(), mode,
             focus_name(mode)}
          after
            Storage.close(handle)
          end

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:ok, [], [], [], %{Mode.none() | away?: Mode.away?(away_path)}, nil}
    end
  end

  defp focus_name(%{focus: nil}), do: nil
  defp focus_name(%{focus: mouse_id}), do: who(Storage.mouse(mouse_id), mouse_id)

  @doc "What `whiska questions` prints: the open list, then what is not actionable."
  @spec render(summary()) :: String.t()
  def render(%{open: open} = summary) do
    slot = Mode.slot(open, summary.mode)

    open_block =
      case open do
        [] -> nothing_waiting()
        _ -> Enum.map_join(open, "\n", &line(&1, slot, summary.mode, summary.focus))
      end

    compose(open_block, summary)
  end

  @doc """
  What `whiska questions --full` prints: every open question in full, oldest
  first, then the same not-actionable blocks the listing shows underneath.

  The same reading as `render/1`, told at length: nobody should have to read a
  line, pick an id out of it and type it back to see what a mouse actually
  said. Each block is its `#<id>` line, then exactly what `whiska questions
  <id>` prints for that one, so the two can never drift apart — given the
  same `on_branch`.
  """
  @spec render_full(summary(), on_branch() | nil, research() | nil, documents() | nil) ::
          String.t()
  def render_full(%{open: open} = summary, on_branch \\ nil, research \\ nil, documents \\ nil) do
    slot = Mode.slot(open, summary.mode)

    open_block =
      case open do
        [] ->
          nothing_waiting()

        _ ->
          Enum.map_join(
            open,
            separator(),
            &("##{&1.id}\n" <>
                full(
                  &1,
                  &1.mouse,
                  slot,
                  summary.mode,
                  summary.focus,
                  on_branch,
                  research,
                  documents
                ))
          )
      end

    compose(open_block, summary)
  end

  @doc "What sits between two questions in `render_full/1`, so the eye finds the break."
  @spec separator() :: String.t()
  def separator, do: "\n\n" <> String.duplicate("─", 60) <> "\n\n"

  defp nothing_waiting, do: "🦉 Nothing needs you · the owl delivers when something does"

  defp compose(open_block, %{orphaned: orphaned, not_taken: not_taken, doorstep: doorstep}) do
    not_taken_block =
      case not_taken do
        [] ->
          nil

        not_taken ->
          not_taken_heading(not_taken) <> Enum.map_join(not_taken, "\n", &line(&1, nil))
      end

    orphaned_block =
      case orphaned do
        [] ->
          nil

        _ ->
          "#{length(orphaned)} orphaned — nothing is left to answer to, so there is nowhere to reply:\n" <>
            Enum.map_join(orphaned, "\n", &line(&1, nil))
      end

    doorstep_block =
      if doorstep > 0,
        do: "#{doorstep} on the doorstep, not collected yet — is the owl running?"

    [open_block, not_taken_block, orphaned_block, doorstep_block]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  # A prompt in the mouse's own session hands an answer over, whoever types it
  # (ADR-0080).
  defp not_taken_heading([_one]),
    do: "1 answer not taken — type anything into the mouse's pane to hand it over:\n"

  defp not_taken_heading(many) do
    "#{length(many)} answers not taken — type anything into a mouse's pane " <>
      "to hand its answer over:\n"
  end

  @doc """
  One question in full: a bold title when a document names the work, the
  `Branch:` line saying where it stands, one `<name>: <target>` line per link
  that has something to open, then the mouse's message — the marker token
  stripped (`Marker.strip/1`) and no `answer:` trailer. The main session
  prints the title and the `Branch:` line as they come and draws the links
  from the link lines (ADR-0089), so no id is in it: the
  person names work by its title or branch, and the main session already
  holds the id it ran this with.

  What `whiska show <id>` prints, and one block of `render_full/1`. `mouse` is
  the question's mouse, or nil when Whiska has no record of it.
  `slot` is the id of the question holding the delivery slot, or nil; it is
  not optional, because a caller that forgot it would print a queued question
  as merely open, and the two would read differently. `mode` is what the
  person set aside and `focus` the focused mouse's name, for the same reason.
  """
  @spec full(
          Question.t(),
          Mouse.t() | nil,
          pos_integer() | nil,
          Mode.t(),
          String.t() | nil,
          on_branch() | nil,
          research() | nil,
          documents() | nil
        ) :: String.t()
  def full(
        %Question{} = q,
        mouse,
        slot,
        mode \\ Mode.none(),
        focus \\ nil,
        on_branch \\ nil,
        research \\ nil,
        documents \\ nil
      ) do
    held = branch_of(q, on_branch)
    found = research_of(q, research)
    more = if is_function(documents, 1), do: documents.(q), else: []

    {rounds, documents} = Enum.split_with(more, &(elem(&1, 0) == "round diff"))

    links =
      ([diff_link(held)] ++ rounds ++ [research_link(found)] ++ documents)
      |> Enum.concat([merge_request_link(held)])
      |> Enum.reject(&is_nil/1)

    head =
      Enum.reject(
        [
          bold(title(q, more, found)),
          "Branch: #{branch_name(mouse, q)} · #{status(q, mouse, held, slot, mode, focus)}"
        ] ++
          Enum.map(links, &"#{elem(&1, 0)}: #{elem(&1, 1)}") ++
          [
            q.typed_blind &&
              "Delivered blind: herdr could not tell whether this session was idle."
          ],
        &(&1 in [nil, false])
      )

    text = q.text |> Marker.strip() |> String.trim_trailing()

    """
    #{Enum.map_join(head, "\n", &String.replace(&1, ~r/\s+/, " "))}

    #{shown(q, text)}
    """
    |> String.trim_trailing()
  end

  # A title, a branch and a file name are the mouse's to write, and the head
  # around them is Whiska's: the title stays inside its bold and holds no link,
  # and a branch or a file name keeps only plain name characters, so none
  # passes for a status or a link.
  defp bold(nil), do: nil
  defp bold(title), do: "**#{String.replace(title, ["*", "[", "]"], "")}**"

  # A sniff mouse is named one, as ADR-0074 has it.
  defp branch_name(%Mouse{branch: branch, mode: "sniff"}, _q) when is_binary(branch),
    do: plain(branch) <> " (sniff)"

  defp branch_name(%Mouse{branch: branch}, _q) when is_binary(branch), do: plain(branch)
  defp branch_name(_mouse, %Question{mouse_id: mouse_id}), do: plain(mouse_id)

  defp plain(name), do: name |> printable() |> String.replace(~r/[^A-Za-z0-9._\/-]/u, "")

  defp plain_file(name), do: name |> printable() |> String.replace(~r/[^A-Za-z0-9._\/-]/u, "?")

  # Where the work stands, read from the question's kind and, for a finished
  # one, from what its branch holds; then what keeps it from the person.
  defp status(q, mouse, held, slot, mode, focus) do
    [standing(q, mouse, held) | waiting(q, slot, mode, focus)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp standing(%Question{kind: "done"}, mouse, held), do: finished(mouse, held)

  defp standing(%Question{reply: true, status: "closed"}, _mouse, _held),
    do: "↩ Replied · its background work still running"

  defp standing(%Question{status: "answered", taken_at: nil}, _mouse, _held),
    do: "Answered · not taken"

  defp standing(%Question{status: status}, _mouse, _held)
       when status in ~w(answered settled orphaned closed superseded),
       do: String.capitalize(status)

  defp standing(%Question{asked_by: "owl"}, _mouse, _held), do: "? Whiska asks"
  defp standing(%Question{kind: "unmarked"}, _mouse, _held), do: "! Stopped without saying why"
  defp standing(_question, _mouse, _held), do: "? Needs your decision"

  defp finished(_mouse, {:ok, %{merge_request: _, not_pushed: n, uncommitted: files}}),
    do: join(["✓ Merge request open", not_pushed(n), uncommitted(files)])

  defp finished(%Mouse{mode: "sniff"}, {:ok, %{ahead: 0, uncommitted: files}}),
    do: join(["✓ Research done", uncommitted(files)])

  defp finished(_mouse, {:ok, %{ahead: 0, base: base, uncommitted: files}}),
    do: join(["Finished", "nothing committed#{beyond(base)}", uncommitted(files)])

  defp finished(_mouse, {:ok, %{ahead: ahead, base: base, uncommitted: files}}),
    do: join(["✓ Ready to merge", commits(ahead) <> beyond(base), uncommitted(files)])

  defp finished(_mouse, {:error, reason}), do: "Finished · branch unknown — #{unknown(reason)}"
  defp finished(_mouse, nil), do: "Finished"

  defp join(parts), do: parts |> Enum.reject(&is_nil/1) |> Enum.join(" · ")

  defp waiting(q, slot, mode, focus) do
    case state(q, slot, mode, focus) do
      "held" -> ["held" <> held_for(q)]
      "queued behind " <> _ -> ["queued", days(q)]
      "waits: " <> _ = waits -> [waits, days(q)]
      _sent_open_or_closed -> [days(q)]
    end
  end

  defp held_for(q) do
    case aged(q) do
      nil -> ""
      age -> " " <> age
    end
  end

  defp days(q) do
    case aged(q) do
      age when is_binary(age) -> if String.ends_with?(age, "d"), do: age
      nil -> nil
    end
  end

  # The work is named by what the person would review: the spec, else the
  # report, else the research, each by its own `# ` title. A finished one is
  # named by its report, which says what is true now.
  defp title(%Question{kind: "done"}, documents, found),
    do: title(Enum.reject(documents, &(elem(&1, 0) in ["spec", "plan"])), found)

  defp title(_question, documents, found), do: title(documents, found)

  defp title(documents, found) do
    Enum.find_value(documents ++ List.wrap(found), fn
      {_label, _link, title} when is_binary(title) -> title
      {_path, title} when is_binary(title) -> title
      _ -> nil
    end)
  end

  defp aged(%Question{asked_at: %DateTime{} = at}),
    do: age(DateTime.diff(DateTime.utc_now(), at))

  defp aged(_question), do: nil

  defp age(seconds) when seconds < 3600, do: "#{max(div(seconds, 60), 1)}m"
  defp age(seconds) when seconds < 86_400, do: "#{div(seconds, 3600)}h"
  defp age(seconds), do: "#{div(seconds, 86_400)}d"

  # A report prints as its summary, the rest behind its link; one that ends on a
  # decision keeps the question it asks (ADR-0089).
  defp shown(%Question{kind: "unmarked"}, text), do: text

  defp shown(q, text) do
    case Report.summary(text) do
      nil -> text
      summary -> summary <> asks(q, summary)
    end
  end

  defp asks(%Question{kind: "needs-decision", text: text}, summary) do
    case Marker.pointer(text) do
      "" -> ""
      pointer -> if String.contains?(summary, pointer), do: "", else: "\n\n" <> pointer
    end
  end

  defp asks(_question, _summary), do: ""

  @typedoc """
  Reads what a question's branch holds, as `Whiska.Git.on_branch/3` answers,
  with `:review` the whole diff's target when there is one, and
  `:merge_request` and `:not_pushed` when one was recorded as opened;
  `{:error, :no_record}` when Whiska has no worktree or branch for its mouse.
  """
  @type on_branch :: (Question.t() -> {:ok, map()} | {:error, term()})

  @typedoc "Finds the research document kept for a question, as its path and title, or nil."
  @type research :: (Question.t() -> {Path.t(), String.t() | nil} | nil)

  @typedoc """
  The other documents a question's mouse asks the person to review, each as
  its label, link and `# ` title, in the order they are linked.
  """
  @type documents :: (Question.t() -> [{String.t(), String.t(), String.t() | nil}])

  @named 3

  # Any question hands over its branch's whole diff and merge request; only a
  # finished one says on its Branch line what its branch holds, since only it
  # is offered a finish.
  defp branch_of(%Question{} = q, on_branch) when is_function(on_branch, 1), do: on_branch.(q)
  defp branch_of(_question, _on_branch), do: nil

  defp merge_request_link({:ok, %{merge_request: url}}), do: {"merge request", printable(url)}
  defp merge_request_link(_held), do: nil

  defp diff_link({:ok, %{review: link}}), do: {"whole diff", link}
  defp diff_link(_held), do: nil

  defp research_of(q, research) when is_function(research, 1), do: research.(q)
  defp research_of(_question, _research), do: nil

  # Read from Whiska's own copy, so it links wherever the question is read
  # from, and after its worktree is gone.
  defp research_link({path, _title}), do: {"research", Review.file_link(path)}
  defp research_link(nil), do: nil

  defp commits(1), do: "1 commit"
  defp commits(n), do: "#{n} commits"

  # The usual base goes unsaid; a mouse cut from another one names it.
  defp beyond(base) when base in ["main", "master"], do: ""
  defp beyond(base), do: " beyond #{base}"

  defp not_pushed(0), do: nil
  defp not_pushed(1), do: "1 commit not pushed"
  defp not_pushed(n), do: "#{n} commits not pushed"

  defp uncommitted([]), do: nil

  defp uncommitted(paths) do
    {named, rest} = Enum.split(paths, @named)
    files = if length(paths) == 1, do: "file", else: "files"
    more = if rest == [], do: "", else: " and #{length(rest)} more"

    "#{length(paths)} #{files} not committed: " <>
      Enum.map_join(named, ", ", &plain_file/1) <> more
  end

  # A path is the mouse's to name. Invalid bytes, controls, format characters
  # and line or paragraph separators all show as `?`, so no name can break or
  # reorder the line the finish options read.
  defp printable(path) do
    path
    |> String.replace_invalid("?")
    |> String.replace(~r/[\p{C}\p{Zl}\p{Zp}]/u, "?")
  end

  defp unknown(:no_worktree), do: "its worktree is gone"
  defp unknown(:no_record), do: "Whiska has no record of its worktree"
  defp unknown(:off_branch), do: "its worktree is not on its branch"
  defp unknown({:base_gone, name}), do: "its base branch #{name} is gone"
  defp unknown(:unsafe_base), do: "its base branch's name is not a plain one"
  defp unknown(:ambiguous_base), do: "there is no one base branch to compare it with"
  defp unknown(_reason), do: "git could not read it"

  @doc """
  One listing line: id, branch, what the mouse did, its pointer, and where it
  stands. `slot` is the id of the question holding the delivery slot, if any;
  `mode` and `focus` as for `full/5`.
  """
  @spec line(Question.t(), pos_integer() | nil, Mode.t(), String.t() | nil) :: String.t()
  def line(%Question{} = q, slot, mode \\ Mode.none(), focus \\ nil) do
    pointer =
      case Marker.pointer(q.text) do
        "" -> ""
        p -> ~s( · "#{String.slice(p, 0, @pointer_max)}")
      end

    "##{q.id}  #{branch(q)}  #{verb(q.kind)}#{pointer}  (#{state(q, slot, mode, focus)})"
  end

  @doc "What the mouse did, as words: asked, or merely stopped (ADR-0009)."
  @spec verb(String.t()) :: String.t()
  def verb("unmarked"), do: "stopped without saying why"
  def verb("done"), do: "finished"
  def verb(_), do: "needs a decision"

  @doc """
  Where a question stands, in the words `whiska questions` prints: held, with its
  mouse; waiting on the person since it was delivered; waiting behind away or
  a focus, or queued behind the question holding the slot, while it is open;
  or its bare status.
  """
  @spec state(Question.t(), pos_integer() | nil, Mode.t(), String.t() | nil) :: String.t()
  def state(question, slot, mode \\ Mode.none(), focus \\ nil)

  def state(%Question{status: "answered", taken_at: %DateTime{} = at}, _slot, _mode, _focus),
    do: "answered, taken #{Calendar.strftime(local(at), "%H:%M")}"

  def state(%Question{status: "answered"}, _slot, _mode, _focus), do: "answered, not taken"

  def state(%Question{status: "sent", sent_at: %DateTime{} = at} = q, _slot, mode, _focus) do
    case Mode.waits(q, mode) do
      :held -> "held"
      _ -> "waiting on you since #{Calendar.strftime(local(at), "%H:%M")}"
    end
  end

  def state(%Question{status: status} = q, slot, mode, focus) do
    case {Mode.waits(q, mode), behind(q, slot)} do
      {:held, _} -> "held"
      {_, _} when status != "open" -> status
      {:away, _} -> "waits: away"
      {{:focus, mouse_id}, _} -> "waits: focus on #{plain(focus || mouse_id)}"
      {nil, nil} -> status
      {nil, behind} -> "queued behind ##{behind}"
    end
  end

  # Stored in UTC, shown in this machine's local time: the person checks these
  # against the clock on their own screen, and a UTC one reads as hours off.
  # Erlang's own conversion follows the OS time zone, so no zone database is
  # needed for the one zone that matters here.
  defp local(%DateTime{} = at) do
    at
    |> DateTime.to_naive()
    |> NaiveDateTime.to_erl()
    |> :calendar.universal_time_to_local_time()
    |> NaiveDateTime.from_erl!()
  end

  @doc """
  The id of the question an open one is queued behind, or nil.

  One question holds the delivery slot at a time and the rest wait for it to
  be answered (ADR-0008), so an open question is waiting on that one, not on
  the person. The
  one rule the sidebar, `whiska questions` and `inbox` all use, so none of them
  can spell the state apart.
  """
  @spec behind(Question.t(), pos_integer() | nil) :: pos_integer() | nil
  def behind(%Question{status: "open", id: id}, slot) when is_integer(slot) and slot != id,
    do: slot

  def behind(_question, _slot), do: nil

  @doc "The id of the question holding the delivery slot among `questions`, or nil."
  @spec slot([Question.t()]) :: pos_integer() | nil
  def slot(questions), do: Enum.find_value(questions, &(&1.status == "sent" && &1.id))

  defp branch(%Question{mouse: %Mouse{branch: branch}}) when is_binary(branch), do: branch
  defp branch(%Question{mouse_id: mouse_id}), do: mouse_id

  @doc "A focused mouse by name: the branch, with `(sniff)` after it for a sniff mouse."
  @spec who(Mouse.t() | nil, String.t()) :: String.t()
  def who(%Mouse{branch: branch, mode: mode}, mouse_id) do
    name = branch || mouse_id
    if mode == "sniff", do: name <> " (sniff)", else: name
  end

  def who(_no_mouse, mouse_id), do: mouse_id

  @doc """
  The questions part of the statusline, with the owl in front when the doorstep
  says it has stopped collecting: detail when there is exactly one thing, a
  count otherwise (ADR-0048). Empty when nothing is waiting. `Whiska.Statusline`
  composes the whole line around `questions_segment/1`, and derives the owl's
  state from the process table as well as `doorstep_stale`, so its owl segment
  is its own.
  """
  @spec statusline(summary()) :: String.t()
  def statusline(summary) do
    [owl_segment(summary), questions_segment(summary)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  @doc """
  An owl that is not collecting, as the doorstep alone can tell, or nil.
  Reported before anything else, because delivery cannot report its own outage
  and this line is the one signal that still works.
  """
  @spec owl_segment(summary()) :: String.t() | nil
  def owl_segment(%{doorstep: doorstep, doorstep_stale: true}),
    do: "🦉 owl down · #{doorstep} waiting"

  def owl_segment(_), do: nil

  @doc "One open question in detail, several as a count, none as nil."
  @spec questions_segment(summary()) :: String.t() | nil
  def questions_segment(%{open: []}), do: nil
  def questions_segment(%{open: [one]}), do: "🐱 " <> single(one)
  def questions_segment(%{open: many}), do: "🐱 #{length(many)} questions waiting"

  defp single(question) do
    case Marker.pointer(question.text) do
      "" -> "#{branch(question)}: ##{question.id}"
      pointer -> "#{branch(question)}: #{clip(pointer)}"
    end
  end

  defp clip(text) do
    if String.length(text) > @segment_max,
      do: String.slice(text, 0, @segment_max - 1) <> "…",
      else: text
  end
end
