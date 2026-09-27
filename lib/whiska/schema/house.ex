defmodule Whiska.Schema.House do
  @moduledoc """
  The one row a house keeps about itself: which pane is its main session.

  Recorded by `whiska start` from the pane it is run in (ADR-0020). Nothing
  else about a house lives here — mice and questions have their own tables.
  """

  use Ecto.Schema

  schema "house" do
    field(:main_pane, :string)
    field(:started_at, :utc_datetime)
  end
end
