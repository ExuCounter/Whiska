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
  not want to see. The commands moved into the `whiska-delivered` skill that
  `whiska init` installs (ADR-0022): the main session's Claude recognises the
  line by its shape — `🐱` first, `#<id>` after the verb — and runs the read
  itself. The id stays in the line because answers are keyed to it (ADR-0005)
  and because that skill needs it. A `done` report is the same line with
  "finished" as its verb: it needs no answer, and nothing in the line says
  otherwise.

  One line, no newline anywhere: `agent.prompt` types into a prompt box, and an
  embedded newline would submit half a notification.
  """

  alias Whiska.Question.Marker
  alias Whiska.Schema.Question

  @pointer_max 120

  @doc """
  Compose the line for a question from the mouse on `branch`, with `more_open`
  questions still waiting behind it. `notes` are the ADR-0008 caveats to append:
  `:status_unknown` when herdr could not say whether the main session is idle.
  """
  @spec compose(Question.t(), String.t(), non_neg_integer(), [atom()]) :: String.t()
  def compose(%Question{} = q, branch, more_open, notes) do
    [
      "🐱 #{branch} #{verb(q.kind)}",
      "##{q.id}",
      pointer(q.text),
      more(more_open)
    ]
    |> Enum.concat(Enum.map(notes, &note/1))
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
    |> String.replace(~r/\s*\n\s*/, " ")
  end

  defp verb("unmarked"), do: "stopped without saying why"
  defp verb("done"), do: "finished"
  defp verb(_), do: "needs a decision"

  defp pointer(text) do
    case Marker.pointer(text) do
      "" -> nil
      p when byte_size(p) > @pointer_max -> ~s("#{String.slice(p, 0, @pointer_max)}…")
      p -> ~s("#{p}")
    end
  end

  defp more(0), do: nil
  defp more(n), do: "#{n} more open"

  defp note(:status_unknown),
    do: "delivered blind: herdr cannot tell whether you are idle, so this may interrupt"
end
