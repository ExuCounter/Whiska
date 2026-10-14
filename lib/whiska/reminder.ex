defmodule Whiska.Reminder do
  @moduledoc """
  Which finished branches the owl hoots about now (ADR-0062).

  A finished report is never delivered (ADR-0009): nothing in it waits on the
  person, so it takes no part in the queue. What it still wants is a finish —
  land it, open a merge request, drop it — and a branch nobody finished is
  work that sits unlanded. So the owl hoots, twice over:

  - **Its finish hoot**, once, as soon as nothing the person set aside stands
    in its way (ADR-0079): a report collected while they are away, focused on
    another branch, or holding this one is hooted once that lifts.
  - **A reminder**, at most once per house every `remind_ms`, naming each
    finished branch whose last hoot is at least that old and which has work of
    its own to land: commits beyond its base. A branch git cannot read is
    counted as having some, since a reminder too many costs less than work
    forgotten. Away silences it, and one that came due
    meanwhile goes out on the first sweep after the person is back; a focus
    elsewhere or a hold leaves that branch for the house's next reminder.

  The reports come from `Whiska.Storage.unhooted/0`, owed their finish hoot
  whatever became of the branch, and `Whiska.Storage.finished/0`, which holds
  back a branch that landed, has a merge request, was taken down, or whose
  mouse asked something or started working since. What is judged here is only time,
  the person's mode and the work. Git is asked about a report only once both
  its house and the report are due, and a report found with nothing to land
  comes back `nothing_to_land`: the house keeps when, and git is not asked about it
  again for another `remind_ms`. Nothing here writes or hoots: the house does
  both, stamping first.
  """

  alias Whiska.Delivery.Mode
  alias Whiska.Git
  alias Whiska.Schema.Mouse
  alias Whiska.Schema.Question

  @typedoc """
  The house as the judgement needs it: what the person set aside, the instant
  judged at, how far apart reminders are, when this house last reminded, when
  each report was last found with nothing to land, and whether a report's
  branch has work of its own to land.
  """
  @type house :: %{
          mode: Mode.t(),
          now: DateTime.t(),
          remind_ms: pos_integer(),
          reminded_at: DateTime.t(),
          nothing_to_land: %{optional(pos_integer()) => DateTime.t()},
          work?: (Question.t() -> boolean())
        }

  @typedoc """
  The reports owed their finish hoot, those a reminder names, and those due a
  reminder but with nothing to land.
  """
  @type due :: %{
          finish: [Question.t()],
          remind: [Question.t()],
          nothing_to_land: [Question.t()]
        }

  @doc "What to hoot about now, out of the house's finished reports."
  @spec due([Question.t()], house()) :: due()
  def due(reports, house) do
    {owed, hooted} =
      reports
      |> Enum.filter(&Mode.deliverable?(&1, house.mode))
      |> Enum.split_with(&is_nil(&1.hooted_at))

    {remind, nothing_to_land} =
      if since?(house.reminded_at, house) do
        hooted
        |> Enum.filter(&(since?(&1.hooted_at, house) and ask_git?(&1, house)))
        |> Enum.split_with(house.work?)
      else
        {[], []}
      end

    %{finish: owed, remind: remind, nothing_to_land: nothing_to_land}
  end

  defp since?(at, house), do: DateTime.diff(house.now, at, :millisecond) >= house.remind_ms

  defp ask_git?(report, house) do
    case Map.fetch(house.nothing_to_land, report.id) do
      {:ok, at} -> since?(at, house)
      :error -> true
    end
  end

  @doc """
  Has this mouse's branch commits of its own beyond its base? Read from the
  main checkout alone: git run in a worktree reads config and programs a mouse
  can write. A branch git will not say plainly about counts as yes.
  """
  @spec work?(Path.t(), Mouse.t()) :: boolean()
  def work?(_main_checkout, %Mouse{branch: nil}), do: false

  def work?(main_checkout, %Mouse{branch: branch, base: base}) do
    case Git.ahead(main_checkout, branch, base) do
      {:ok, 0} -> false
      _some_or_unknown -> true
    end
  end
end
