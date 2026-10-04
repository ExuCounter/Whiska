defmodule Whiska.Migrations.V009ShapedAs do
  @moduledoc """
  The mode a mouse was shaped as (ADR-next-a-finished-investigation-hands-off).

  `whiska shape` chooses the model and effort against the work the mode names,
  and records that mode here as well as in `mode`. `whiska mode` moves `mode`
  and leaves this alone, so a mouse moved off its shape — a sniff mouse
  flipped to build — still says what its model and effort were chosen for.

  Nil for every mouse already in the house: what each was shaped as before
  this column existed is not known, and a guess would be a claim.
  """

  use Ecto.Migration

  def change do
    alter table(:mice) do
      add(:shaped_as, :string)
    end
  end
end
