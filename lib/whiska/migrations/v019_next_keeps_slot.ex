defmodule Whiska.Migrations.V019NextKeepsSlot do
  @moduledoc """
  Somewhere to say a mouse's next message inherits the delivery slot
  (ADR-0008).

  `whiska send` supersedes the questions its mouse was waiting on at once, so
  when the mouse's reply is collected there is no earlier question left for it
  to inherit the slot from. `next_keeps_slot` carries it over: set by the
  letter when what it superseded held the slot, spent by the mouse's next
  collected message. Version 20 renames it `reply_goes_next`.
  """

  use Ecto.Migration

  def change do
    alter table(:mice) do
      add(:next_keeps_slot, :boolean, default: false, null: false)
    end
  end
end
