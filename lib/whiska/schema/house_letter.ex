defmodule Whiska.Schema.HouseLetter do
  @moduledoc """
  A letter another repo's main session left in this house with `whiska tell`
  (ADR-0044): the sending repo's name and main checkout, the copy of the file
  in this house, when it was left, and when delivery was done with it: typed
  its one line into this house's main session, or skipped it as no letter it
  could type.
  """

  use Ecto.Schema

  schema "house_letters" do
    field(:from_repo, :string)
    field(:from_checkout, :string)
    field(:path, :string)
    field(:left_at, :utc_datetime)
    field(:typed_at, :utc_datetime)
  end
end
