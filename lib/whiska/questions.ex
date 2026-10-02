defmodule Whiska.Questions do
  @moduledoc """
  What is waiting on the person in one house — asked once, shown three ways.

  `whiska questions` and the project statusline both answer "how many questions
  are open here". The spec has the statusline read the underlying data directly
  rather than shelling out to the command, so the reading lives here and each
  caller only renders: `render/1` for the listing, `render_full/1` for the same
  thing at length (`whiska questions --full`), and `statusline/1` for the one
  segment the statusline appends (ADR-0027). A statusline that disagreed with
  the listing about what is waiting would be worse than either alone.

  Three sources, each asked for what only it knows: the house's open and sent
  questions (`Whiska.Storage.questions/0`), its orphaned ones — shown apart and
  never counted, since there is nowhere to reply (ADR-0036) — and the doorstep,
  whose uncollected entries the database cannot see at all.

  Nothing here writes. A house Whiska has never opened is left unopened; the
  doorstep is read, never collected — collection is the owl's job (ADR-0036).
  """

  alias Whiska.Doorstep
  alias Whiska.Question.Marker
  alias Whiska.Schema.Mouse
  alias Whiska.Schema.Question
  alias Whiska.Storage

  # An entry sitting uncollected longer than the owl's backstop is evidence the
  # owl is not collecting. Until the owl answers a socket (ADR-0027), age is the
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
          doorstep: non_neg_integer(),
          doorstep_stale: boolean()
        }

  @doc """
  Everything waiting in the house whose main checkout this is.

  `open` (open and sent) and `orphaned` come from the database; `doorstep`
  counts entries the owl has not collected yet, and `doorstep_stale` says
  whether any has waited past the backstop. A house with no database yet is
  simply empty — it is not created.
  """
  @spec summary(Path.t()) :: {:ok, summary()} | {:error, term()}
  def summary(main_checkout) do
    with {:ok, open, orphaned} <- read_house(main_checkout) do
      waiting = Doorstep.waiting(main_checkout)
      now = DateTime.utc_now()

      stale =
        Enum.any?(waiting, fn {_file, entry} ->
          DateTime.diff(now, entry.stamped_at, :second) > @backstop_s
        end)

      {:ok, %{open: open, orphaned: orphaned, doorstep: length(waiting), doorstep_stale: stale}}
    end
  end

  defp read_house(main_checkout) do
    if File.exists?(Storage.database_path(main_checkout)) do
      case Storage.open(main_checkout) do
        {:ok, handle} ->
          try do
            {:ok, Storage.questions(), Storage.orphaned_questions()}
          after
            Storage.close(handle)
          end

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:ok, [], []}
    end
  end

  @doc "What `whiska questions` prints: the open list, then what is not actionable."
  @spec render(summary()) :: String.t()
  def render(%{open: open} = summary) do
    open_block =
      case open do
        [] -> nothing_waiting()
        _ -> Enum.map_join(open, "\n", &line/1)
      end

    compose(open_block, summary)
  end

  @doc """
  What `whiska questions --full` prints: every open question in full, oldest
  first, then the same not-actionable blocks the listing shows underneath.

  The same reading as `render/1`, told at length: nobody should have to read a
  line, pick an id out of it and type it back to see what a mouse actually
  said. Each block is exactly what `whiska questions <id>` prints for that one,
  so the two can never drift apart.
  """
  @spec render_full(summary()) :: String.t()
  def render_full(%{open: open} = summary) do
    open_block =
      case open do
        [] -> nothing_waiting()
        _ -> Enum.map_join(open, separator(), &full/1)
      end

    compose(open_block, summary)
  end

  @doc "What sits between two questions in `render_full/1`, so the eye finds the break."
  @spec separator() :: String.t()
  def separator, do: "\n\n" <> String.duplicate("─", 60) <> "\n\n"

  defp nothing_waiting, do: "🦉 Nothing needs you · the owl delivers when something does"

  defp compose(open_block, %{orphaned: orphaned, doorstep: doorstep}) do
    orphaned_block =
      case orphaned do
        [] ->
          nil

        _ ->
          "#{length(orphaned)} orphaned — nothing is left to answer to, so there is nowhere to reply:\n" <>
            Enum.map_join(orphaned, "\n", &line/1)
      end

    doorstep_block =
      if doorstep > 0,
        do: "#{doorstep} on the doorstep, not collected yet — is the owl running?"

    [open_block, orphaned_block, doorstep_block]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  @doc """
  One question in full: the heading, then the mouse's whole message as a
  person reads it — the marker token stripped (`Marker.strip/1`) and no
  `answer:` trailer, since the heading carries the id and the CLAUDE.md block
  says how to reply. Plumbing stays out of what the person reads.

  What `whiska questions <id>` prints, and one block of `render_full/1`. The
  branch comes from the question's own preloaded mouse; a caller that loaded
  the question without it passes the branch itself.
  """
  @spec full(Question.t()) :: String.t()
  def full(%Question{} = q), do: full(q, branch(q))

  @spec full(Question.t(), String.t()) :: String.t()
  def full(%Question{} = q, branch) do
    """
    ##{q.id}  #{branch}  #{verb(q.kind)}  (#{state(q)}, asked #{Calendar.strftime(q.asked_at, "%Y-%m-%d %H:%M")})

    #{q.text |> Marker.strip() |> String.trim_trailing()}
    """
    |> String.trim_trailing()
  end

  @doc "One listing line: id, branch, what the mouse did, its pointer, and where it stands."
  @spec line(Question.t()) :: String.t()
  def line(%Question{} = q) do
    pointer =
      case Marker.pointer(q.text) do
        "" -> ""
        p -> ~s( · "#{String.slice(p, 0, @pointer_max)}")
      end

    "##{q.id}  #{branch(q)}  #{verb(q.kind)}#{pointer}  (#{state(q)})"
  end

  @doc "What the mouse did, as words: asked, or merely stopped (ADR-0009)."
  @spec verb(String.t()) :: String.t()
  def verb("unmarked"), do: "stopped without saying why"
  def verb("done"), do: "finished"
  def verb(_), do: "needs a decision"

  @doc "Where a question stands: its status, with the time it was delivered when sent."
  @spec state(Question.t()) :: String.t()
  def state(%Question{status: "sent", sent_at: %DateTime{} = at}),
    do: "sent #{Calendar.strftime(at, "%H:%M")}"

  def state(%Question{status: status}), do: status

  defp branch(%Question{mouse: %Mouse{branch: branch}}) when is_binary(branch), do: branch
  defp branch(%Question{mouse_id: mouse_id}), do: mouse_id

  @doc """
  The questions part of the statusline, with the owl in front when the doorstep
  says it has stopped collecting: detail when there is exactly one thing, a
  count otherwise (ADR-0027). Empty when nothing is waiting. `Whiska.Statusline`
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
