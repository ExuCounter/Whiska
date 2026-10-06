defmodule Whiska.Schema.House do
  @moduledoc """
  The one row a house keeps about itself: which pane is its main session, and
  which mouse it is focused on.

  The pane is recorded by `whiska start` from the pane it is run in (ADR-0020).
  The focus is the `mouse_id` whose questions alone reach that pane while it is
  set (ADR-next-the-person-decides-what-reaches-them). Nothing else about a
  house lives here — mice and questions have their own tables.
  """

  use Ecto.Schema

  schema "house" do
    field(:main_pane, :string)
    field(:started_at, :utc_datetime)
    field(:focus, :string)
  end
end
