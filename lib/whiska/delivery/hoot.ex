defmodule Whiska.Delivery.Hoot do
  @moduledoc """
  The desktop notification the owl raises as it delivers a question.

  Delivery types a line into the main session's prompt box. That line only
  helps the person who is looking at that terminal; the whole point of leaving
  a question on the doorstep is that they are somewhere else. The hoot is the
  part that reaches them there, and it goes out at the same moment the line is
  typed, from the same place in the code, so the two can never disagree about
  what happened (ADR-0062).

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

  herdr is asked first, and decides from the person's own `[ui.toast]` and
  `[ui.sound]` settings whether to draw it. When it says it did not because
  popups are off (`disabled`) or nobody is attached to see one
  (`no_foreground_client`), the hoot is raised on the desktop instead
  (ADR-0071): `[ui.toast] delivery` is one
  switch over two decisions, and turning off herdr's toast for every agent is
  not asking for Whiska's to go quiet. `rate_limited` and `busy` are herdr
  pacing itself, and a fallback would defeat the pacing; an error leaves it
  unknown whether herdr drew one. Neither falls back.

  The sound is the one judgement here. A question that needs a decision is the
  one that must not be missed, so it takes herdr's `request` sound; a finished
  branch takes `done`. Both hoot — a finished branch that nobody hears about is
  the silence ADR-0008's note of 2026-10-01 went out of its way to remove — but
  they are told apart without looking.
  """

  alias Whiska.Delivery.Text
  alias Whiska.Herdr
  alias Whiska.Schema.Question

  @typedoc "A notification, in herdr's own terms (`Whiska.Herdr.notification/0`)."
  @type t :: %{title: String.t(), body: String.t(), sound: :done | :request}

  # A branch and a house name are somebody else's text — a branch arrives in
  # the doorstep entry a mouse's own hook wrote — so the title is flattened and
  # cut rather than trusted to be one short line. `Whiska.Delivery.Text` does
  # the same to the line it composes, for the same reason.
  @name_max 40

  @falls_back ["disabled", "no_foreground_client"]

  @typedoc "What herdr did with a hoot, and what the desktop did after it."
  @type outcome :: {Herdr.notify_result(), Whiska.Desktop.result() | :not_needed}

  @doc """
  Raise `hoot` through herdr, and on the desktop when herdr says it will not
  show it. Never raises: whatever either side does wrong comes back as an
  answer.
  """
  @spec send_out(module(), Path.t(), module(), t()) :: outcome()
  def send_out(herdr, socket, desktop, hoot) do
    case attempt(fn -> herdr.notify(socket, hoot) end) do
      {:ok, {:not_shown, reason}} = answer when reason in @falls_back ->
        {answer, attempt(fn -> desktop.notify(hoot) end)}

      answer ->
        {answer, :not_needed}
    end
  end

  defp attempt(call) do
    call.()
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @doc """
  Compose the hoot for a question from the mouse on `branch`, in the house
  named `house`, with `more_open` questions still waiting behind it.
  """
  @spec compose(Question.t(), String.t(), String.t(), non_neg_integer()) :: t()
  def compose(%Question{} = q, house, branch, more_open) do
    %{
      title: "🐱 #{name(house)} · #{name(branch)} #{Text.verb(q.kind)}",
      body: body(q, more_open),
      sound: sound(q.kind)
    }
  end

  @doc """
  The hoot for an answer its mouse never took, after the owl rang for it as
  often as it will (ADR-next-an-answer-is-taken-not-typed). Any prompt in that
  mouse's pane hands the answer over, so that is what it says to do.
  """
  @spec not_taken(Question.t(), String.t(), String.t()) :: t()
  def not_taken(%Question{id: id}, house, branch) do
    %{
      title: "🐱 #{name(house)} · #{name(branch)} has not taken your answer",
      body: "##{id} · type anything into its pane to hand it over",
      sound: :request
    }
  end

  defp name(text) do
    case String.replace(text, ~r/\s+/, " ") do
      flat when byte_size(flat) > @name_max -> String.slice(flat, 0, @name_max) <> "…"
      flat -> flat
    end
  end

  defp body(q, more_open) do
    ["##{q.id}", Text.pointer(q.text), Text.more(more_open)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  defp sound("done"), do: :done
  defp sound(_), do: :request
end
