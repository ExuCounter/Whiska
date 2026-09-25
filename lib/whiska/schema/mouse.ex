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
    # Set once herdr is in the picture; v0.0.1 never talks to herdr (ADR-0030).
    field(:pane, :string)
    field(:path, :string)
    field(:branch, :string)
    # Stored from day one, read by nothing in v0.0.1 (ADR-0018, ADR-0030).
    field(:mode, :string, default: "build")
    field(:created_at, :utc_datetime)
  end
end
