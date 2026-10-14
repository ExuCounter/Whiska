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
    # Which deny list `whiska shape` starts it with (ADR-0069).
    field(:mode, :string, default: "build")
    # The model and effort the spawn asked for; nil is the person's own
    # default (ADR-0069).
    field(:model, :string)
    field(:effort, :string)
    # The model id its latest turn actually ran on, read from its transcript:
    # what the alias resolved to, or what Claude Code fell back to.
    field(:ran_on, :string)
    # When `whiska shape` gave this mouse its mode. Nil means nobody did, and
    # it started with no deny list (ADR-0069).
    field(:shaped_at, :utc_datetime)
    # The mode `whiska shape` recorded, which the model and effort were chosen
    # with; nil when no spawn ever shaped it. A mouse flipped before ADR-0074
    # can differ from `mode`, and `whiska mice` says so.
    field(:shaped_as, :string)
    # The branch the main checkout was on when this mouse was spawned, so the
    # one its worktree was cut from: what its branch is measured against.
    # Nil when nobody recorded one, which reads as the default branch.
    field(:base, :string)
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
    # When the person's "Open a merge request / PR" succeeded, and the link it
    # printed: a finished line then offers what fits an open merge request, and
    # the owl fetches the base so a merge on the forge is seen here.
    field(:merge_request_at, :utc_datetime)
    field(:merge_request_url, :string)
  end

  @doc """
  A recorded merge request waits until its branch is seen landed. One recorded
  after that landing is a new request, and waits in turn.
  """
  @spec merge_request_waiting?(%__MODULE__{}) :: boolean()
  def merge_request_waiting?(%__MODULE__{merge_request_at: nil}), do: false
  def merge_request_waiting?(%__MODULE__{landed_at: nil}), do: true

  def merge_request_waiting?(%__MODULE__{merge_request_at: at, landed_at: landed}),
    do: DateTime.compare(at, landed) == :gt
end
