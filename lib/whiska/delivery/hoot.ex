defmodule Whiska.Delivery.Hoot do
  @moduledoc """
  The desktop notification the owl raises as it delivers a question, as a
  finished report arrives, and to remind the person of finished branches
  nobody landed (ADR-0062).

  Delivery types a line into the main session's prompt box. That line only
  helps the person who is looking at that terminal; the whole point of leaving
  a question on the doorstep is that they are somewhere else. The hoot is the
  part that reaches them there, and it goes out at the same moment the line is
  typed, from the same place in the code, so the two can never disagree about
  what happened (ADR-0062).

  The line is only a cat (ADR-0009), so the hoot says what the question is:
  the house, the branch and the verb, then the id, the pointer and how many
  more are open — `Text.verb/1`, `Text.pointer/1` and `Text.more/1`. A
  notification arrives with no context at all, and the person has several
  repos going at once.

  What it leaves out is ADR-0008's `status_unknown` caveat: the block
  `whiska show` prints says it, on the screen that was typed into; a
  notification has room for the branch and the verb and nothing more.

  It is raised on the desktop and never through herdr (ADR-0062): herdr's
  `[ui.toast] delivery` is one switch over its own agent toasts, a mouse's
  included, and every notification sent through its API, and with the switch
  off it still answers `shown: true`. Whiska is the only source, and only for
  what waits on the person in a main session.

  The sound is the one judgement here. A question that needs a decision is the
  one that must not be missed, so it takes the `request` sound; a finished
  branch takes `done`. Both hoot, but they are told apart without looking.

  A finished report hoots as it is collected, and its line is typed later,
  once nothing waits (ADR-0008), with no hoot of its own: it says the verb, the
  id and the pointer, with nothing waiting behind it. A reminder names every finished branch it is
  about, with how long ago each finished, in one hoot per house.
  """

  alias Whiska.Delivery.Text
  alias Whiska.Report
  alias Whiska.Schema.Question

  @typedoc "A notification (`Whiska.Desktop.notification/0`), before the house adds where a click goes."
  @type t :: %{title: String.t(), body: String.t(), sound: :done | :request}

  # A branch and a house name are somebody else's text — a branch arrives in
  # the doorstep entry a mouse's own hook wrote — so each is made one plain
  # line and cut rather than trusted to be one short line.
  @name_max 40

  @pointer_max 120

  @reminder_names 8

  @doc """
  Raise `hoot` on the desktop. Never raises: whatever the notifier does wrong
  comes back as an answer.
  """
  @spec send_out(module(), Whiska.Desktop.notification()) :: Whiska.Desktop.result()
  def send_out(desktop, hoot) do
    desktop.notify(hoot)
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @doc """
  Compose the hoot for a question from the mouse on `branch`, in the house
  named `house`, with `more` still waiting behind it.
  """
  @spec compose(Question.t(), String.t(), String.t(), Text.more()) :: t()
  def compose(%Question{} = q, house, branch, more) do
    %{
      title: title(q, name(house), name(branch)),
      body: body(q, more),
      sound: sound(q.kind)
    }
  end

  @doc """
  The hoot for an answer its mouse never took, after the owl rang for it as
  often as it will (ADR-0080). Any prompt in that
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

  @doc """
  The reminder for finished branches nobody landed or opened a merge request
  for (ADR-0062), each reported with how long ago it finished, as of `now`.
  Eight are named at most, and the rest counted, so it stays one glance.
  """
  @spec reminder([Question.t()], String.t(), DateTime.t()) :: t()
  def reminder(reports, house, now) do
    {named, rest} = Enum.split(reports, @reminder_names)
    more = if rest == [], do: "", else: ", and #{length(rest)} more"

    %{
      title: "🐱 #{name(house)} · #{length(reports)} finished, not landed",
      body: "no merge request: " <> Enum.map_join(named, ", ", &aged(&1, now)) <> more,
      sound: :done
    }
  end

  @doc """
  The one hoot for the branches of a house whose login expired in the same
  sweep (ADR-0067). Only the person can log in again, and once they have, in
  any session, every one of them carries on by itself at its next pickup.
  """
  @spec login_expired([String.t()], String.t()) :: t()
  def login_expired(branches, house) do
    {named, rest} = Enum.split(branches, @reminder_names)
    more = if rest == [], do: "", else: ", and #{length(rest)} more"

    %{
      title: "🔑 #{name(house)} · login expired",
      body:
        "run /login in any session; " <>
          Enum.map_join(named, ", ", &name/1) <> more <> carries_on(branches),
      sound: :request
    }
  end

  defp carries_on([_one]), do: " carries on by itself"
  defp carries_on(_many), do: " carry on by themselves"

  @doc """
  The one hoot for a branch whose turn keeps dying on an API error, after
  `pickups` pickups, or whose error never clears by itself (ADR-0067).
  """
  @spec stalled(String.t(), String.t(), non_neg_integer(), String.t()) :: t()
  def stalled(branch, "server_error", pickups, house) do
    %{
      title: "✖ #{name(house)} · #{name(branch)} keeps failing on an API error",
      body: "picked up #{pickups} times, still retrying every 30 minutes at most",
      sound: :request
    }
  end

  def stalled(branch, kind, _pickups, house) do
    %{
      title: "✖ #{name(house)} · #{name(branch)} stopped on an API error",
      body: "#{name(kind)}: not retried, it will not clear by itself — look at its pane",
      sound: :request
    }
  end

  @doc """
  The one hoot for a mouse herdr restored without its launch flags and Whiska
  could not start again with them (ADR-0044).
  """
  @spec not_restarted(String.t(), String.t()) :: t()
  def not_restarted(branch, house) do
    %{
      title: "✖ #{name(house)} · #{name(branch)} runs without its launch flags",
      body:
        "herdr restored it without them and Whiska could not restart it — look at its " <>
          "pane: if Claude is gone, start it again with `claude --resume` and the flags " <>
          "`whiska shape` prints",
      sound: :request
    }
  end

  defp aged(%Question{mouse: mouse, mouse_id: mouse_id, asked_at: asked_at}, now) do
    branch =
      case mouse do
        %Whiska.Schema.Mouse{branch: branch} when is_binary(branch) -> branch
        _ -> mouse_id
      end

    "#{name(branch)} (#{age(DateTime.diff(now, asked_at))})"
  end

  defp age(seconds) when seconds < 3600, do: "#{max(div(seconds, 60), 0)}m"
  defp age(seconds) when seconds < 86_400, do: "#{div(seconds, 3600)}h"
  defp age(seconds), do: "#{div(seconds, 86_400)}d"

  defp title(q, house, branch) do
    if Question.owls?(q),
      do: "🦉 #{house} · Whiska asks about #{branch}",
      else: "🐱 #{house} · #{branch} #{Text.verb(q.kind)}"
  end

  defp name(text), do: Whiska.Watch.Text.plain(text, @name_max)

  defp body(q, more) do
    ["##{q.id}", pointer(q), Text.more(more)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  defp pointer(%Question{kind: "done", text: text}) do
    case Whiska.Watch.Text.plain(Report.outcome(text), @pointer_max) do
      "" -> nil
      outcome -> ~s("#{outcome}")
    end
  end

  defp pointer(%Question{text: text}), do: Text.pointer(text)

  defp sound("done"), do: :done
  defp sound(_), do: :request
end
