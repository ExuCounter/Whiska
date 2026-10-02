defmodule Whiska.Delivery.Hoot do
  @moduledoc """
  The desktop notification the owl raises as it delivers a question.

  Delivery types a line into the main session's prompt box. That line only
  helps the person who is looking at that terminal; the whole point of leaving
  a question on the doorstep is that they are somewhere else. The hoot is the
  part that reaches them there, and it goes out at the same moment the line is
  typed, from the same place in the code, so the two can never disagree about
  what happened (ADR-0060).

  It says what the line says, in the line's own words — `Text.verb/1`,
  `Text.pointer/1` and `Text.more/1` are shared rather than copied, because a
  second phrasing of one event is a second event as far as the person reading
  it is concerned. The one thing it adds is the house: the line is read inside
  a house and needs no name for it, while a notification arrives with no
  context at all, and the person has several repos going at once.

  What it leaves out is ADR-0008's `status_unknown` caveat. That note exists to
  explain an interruption to the person whose terminal has just been typed
  into, and it is on the screen when they look; a notification has room for the
  branch and the verb and nothing more.

  The sound is the one judgement here. A question that needs a decision is the
  one that must not be missed, so it takes herdr's `request` sound; a finished
  branch takes `done`. Both hoot — a finished branch that nobody hears about is
  the silence ADR-0008's note of 2026-10-01 went out of its way to remove — but
  they are told apart without looking.
  """

  alias Whiska.Delivery.Text
  alias Whiska.Schema.Question

  @typedoc "A notification, in herdr's own terms (`Whiska.Herdr.notification/0`)."
  @type t :: %{title: String.t(), body: String.t(), sound: :done | :request}

  @doc """
  Compose the hoot for a question from the mouse on `branch`, in the house
  named `house`, with `more_open` questions still waiting behind it.
  """
  @spec compose(Question.t(), String.t(), String.t(), non_neg_integer()) :: t()
  def compose(%Question{} = q, house, branch, more_open) do
    %{
      title: "🐱 #{house} · #{branch} #{Text.verb(q.kind)}",
      body: body(q, more_open),
      sound: sound(q.kind)
    }
  end

  defp body(q, more_open) do
    ["##{q.id}", Text.pointer(q.text), Text.more(more_open)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  defp sound("done"), do: :done
  defp sound(_), do: :request
end
