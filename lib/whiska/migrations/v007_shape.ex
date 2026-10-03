defmodule Whiska.Migrations.V007Shape do
  @moduledoc """
  Somewhere to keep a mouse's shape (ADR-0069).

  `model` is the Claude model alias the spawn started it on, or nil for the
  person's own default. `shaped_at` is when `whiska shape` recorded it; nil
  means nobody chose its mode — the spawn skipped `whiska shape` — and such a
  mouse may read but not write until somebody does.

  Every mouse already in the house is stamped as shaped: it was running as
  build when the rule arrived, and it is not to be stopped mid-task for a step
  its spawn could not have taken.
  """

  use Ecto.Migration

  def change do
    alter table(:mice) do
      add(:model, :string)
      add(:shaped_at, :utc_datetime)
    end

    execute(
      "UPDATE mice SET shaped_at = created_at",
      "SELECT 1"
    )
  end
end
