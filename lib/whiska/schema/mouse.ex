defmodule Whiska.Schema.Mouse do
  @moduledoc """
  Whiska's own persisted row tracking a mouse.

  Outlives the mouse itself — a dead mouse still has a mouse record, marked dead
  rather than deleted (ADR-0007). Keyed by `mouse_id`, the opaque marker-file id
  (ADR-0002); `pane`, `path` and `branch` are live labels hanging off that key,
  never the key itself.
  """

  use Ecto.Schema

  @primary_key {:mouse_id, :string, autogenerate: false}
  @derive {Inspect, only: [:mouse_id, :branch, :mode, :model, :effort, :ran_on]}

  schema "mice" do
    # The herdr pane hosting this mouse, found by matching the pane's cwd to
    # `path` when the house opens or the pane's agent is detected.
    field(:pane, :string)
    field(:path, :string)
    field(:branch, :string)
    # Read by the sniff rule on every tool call (ADR-0069).
    field(:mode, :string, default: "build")
    # The model and effort the spawn asked for; nil is the person's own
    # default (ADR-0069).
    field(:model, :string)
    field(:effort, :string)
    # The model id its latest turn actually ran on, read from its transcript:
    # what the alias resolved to, or what Claude Code fell back to.
    field(:ran_on, :string)
    # When somebody chose this mouse's mode — `whiska shape`, or `whiska mode`.
    # Nil means nobody did, and the mouse may read but not write (ADR-0069).
    field(:shaped_at, :utc_datetime)
    # The mode `whiska shape` recorded, which the model and effort were chosen
    # with; nil when no spawn ever shaped it. A mouse flipped before ADR-0074
    # can differ from `mode`, and `whiska mice` says so.
    field(:shaped_as, :string)
    field(:created_at, :utc_datetime)
    # Set when herdr reports the pane gone (ADR-0026); cleared if a pane comes
    # back on the same worktree. Never a reason to delete the row (ADR-0007).
    field(:died_at, :utc_datetime)
    # Set when the owl takes the worktree down (ADR-0061). The row stays; this
    # is what makes it permanently inert.
    field(:removed_at, :utc_datetime)
    # When herdr last said this pane had started working, and when the owl last
    # typed a line into it to carry a died turn on (ADR-0067).
    field(:worked_at, :utc_datetime)
    field(:picked_up_at, :utc_datetime)
    # Set when the sweep first sees this branch merged into the base (ADR-0064).
    # What makes the difference between a question this mouse left that the
    # merge answered and one nobody ever dealt with.
    field(:landed_at, :utc_datetime)
    # Set when the person put this mouse on hold (`hold <branch>`): its next
    # tool call is refused and nothing of its is delivered until `resume`
    # clears it (ADR-0079).
    field(:held_at, :utc_datetime)
  end
end
