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
  @derive {Inspect, only: [:mouse_id, :branch, :mode]}

  schema "mice" do
    # The herdr pane hosting this mouse, found by matching the pane's cwd to
    # `path` when the house opens or the pane's agent is detected.
    field(:pane, :string)
    field(:path, :string)
    field(:branch, :string)
    # Stored from day one, read by nothing in v0.0.1 (ADR-0018, ADR-0030).
    field(:mode, :string, default: "build")
    field(:created_at, :utc_datetime)
    # Set when herdr reports the pane gone (ADR-0026); cleared if a pane comes
    # back on the same worktree. Never a reason to delete the row (ADR-0007).
    field(:died_at, :utc_datetime)
    # Set when the owl takes the worktree down (ADR-0058). The row stays; this
    # is what makes it permanently inert.
    field(:removed_at, :utc_datetime)
  end
end
