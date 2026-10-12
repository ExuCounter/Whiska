defmodule Whiska.Migrations.V014KeepsSlot do
  @moduledoc """
  Somewhere to say a question inherited the delivery slot (ADR-0008).

  `keeps_slot` is set on a mouse's newer question when it supersedes one that
  held the slot — sent, or itself an heir not yet delivered — so it goes next,
  ahead of every other branch's. The questions already in the house stay
  unset: which of them inherited is not known.
  """

  use Ecto.Migration

  def change do
    alter table(:questions) do
      add(:keeps_slot, :boolean, default: false, null: false)
    end
  end
end
