defmodule Whiska.Migrations.V002OwlCollection do
  @moduledoc """
  What the owl needs that v0.0.1 did not: a mouse can die, and a collected
  question has two more shapes.

  `died_at` is the whole of dead-mouse state (ADR-0026): a dead mouse is marked,
  never deleted (ADR-0007), and `whiska reopen` clears the stamp on the same row
  later. Kinds and statuses are plain strings checked in `Whiska.Storage`, so the
  new `unmarked` kind (ADR-0009) and `closed` status (a `done` report, closed on
  arrival) need no schema change of their own — this migration exists for the
  column.
  """

  use Ecto.Migration

  def change do
    alter table(:mice) do
      add(:died_at, :utc_datetime)
    end
  end
end
