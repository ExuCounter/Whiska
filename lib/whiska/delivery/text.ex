defmodule Whiska.Delivery.Text do
  @moduledoc """
  The one line the owl types into the main session.

  A pointer, not the message. The full text is one command away (`whiska
  questions <id>`), which is the spec's "full detail fetched just before each
  one is asked". The line carries what the person needs to decide whether to
  look now: which branch, whether it asked, finished, or merely stopped
  (ADR-0009), the id, the mouse's own pointer, and how many more are waiting
  behind it.

  It carries no command. An earlier shape ended in `read: whiska questions
  <id>` and `answer: whiska reply <id> "..."`, so the person could see what to
  type next; that made the line read like code, which is what the person did
  not want to see. The main session's brief carries the commands instead: its
  Claude recognises the line by its shape — `🐱` first, or `🦉 Whiska asks`
  for the owl's own question, `#<id>` after the verb — and runs `whiska show`
  itself. The id stays in the line because
  answers are keyed to it (ADR-0005) and because that read needs it. A `done`
  report is never typed (ADR-0009); its verb, "finished", is still said by
  its hoot.

  One line, no newline anywhere: `agent.prompt` types into a prompt box, and an
  embedded newline would submit half a notification.
  """

  alias Whiska.Question.Marker
  alias Whiska.Schema.Question

  @pointer_max 120

  @typedoc "What is still waiting behind a line: every other open question."
  @type more :: %{open: non_neg_integer()}

  @doc """
  Compose the line for a question from the mouse on `branch`, with `more`
  still waiting behind it. `notes` are the ADR-0008 caveats to append:
  `:status_unknown` when herdr could not say whether the main session is idle.
  """
  @spec compose(Question.t(), String.t(), more(), [atom()]) :: String.t()
  def compose(%Question{} = q, branch, more, notes) do
    [
      if(Question.owls?(q),
        do: "🦉 Whiska asks · #{branch} #{verb(q.kind)}",
        else: "🐱 #{branch} #{verb(q.kind)}"
      ),
      "##{q.id}",
      pointer(q.text),
      more(more)
    ]
    |> Enum.concat(Enum.map(notes, &note/1))
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
    |> String.replace(~r/\s*\n\s*/, " ")
  end

  @doc """
  What the mouse did, in the words the line says it in: `needs a decision`,
  `finished`, or `stopped without saying why`.

  Public because the hoot that goes out with the line says the same thing
  (`Whiska.Delivery.Hoot`), and the person must never meet two phrasings of one
  event.
  """
  @spec verb(String.t()) :: String.t()
  def verb("unmarked"), do: "stopped without saying why"
  def verb("done"), do: "finished"
  def verb(_), do: "needs a decision"

  @doc """
  The mouse's own pointer, quoted and cut to length, or `nil` when it left
  none. Shared with the hoot, for the reason `verb/1` is.
  """
  @spec pointer(String.t()) :: String.t() | nil
  def pointer(text) do
    case Marker.pointer(text) do
      "" -> nil
      p when byte_size(p) > @pointer_max -> ~s("#{String.slice(p, 0, @pointer_max)}…")
      p -> ~s("#{p}")
    end
  end

  @doc "What is still waiting behind this one, or `nil` for nothing."
  @spec more(more()) :: String.t() | nil
  def more(%{open: 0}), do: nil
  def more(%{open: n}), do: "#{n} more open"

  defp note(:status_unknown),
    do: "delivered blind: herdr cannot tell whether you are idle, so this may interrupt"
end
