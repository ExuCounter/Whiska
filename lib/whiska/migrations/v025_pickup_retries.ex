defmodule Whiska.Migrations.V025PickupRetries do
  @moduledoc """
  What a mouse whose turn keeps dying on an API error is waiting out
  (ADR-0067).

  `pickups` counts the pickups since the mouse last finished a turn, which is
  what the wait before the next one grows with. The stall is the error the
  sweep last judged it waiting on: its kind, when the next pickup is due (nil
  for a kind that is never picked up), how many pickups of the run failed, when
  this run of failures began, and when the person was told of it. A stall is current while nothing of the
  mouse's has reached the doorstep since `stalled_at`.
  """

  use Ecto.Migration

  @columns [
    pickups: "INTEGER NOT NULL DEFAULT 0",
    stall_kind: "TEXT",
    retry_at: "TEXT",
    stall_failed: "INTEGER NOT NULL DEFAULT 0",
    stalled_at: "TEXT",
    stall_hooted_at: "TEXT"
  ]

  # A house that ran an earlier draft of this migration under another number
  # holds some of these columns already, so each is added only if missing.
  def up do
    have = existing()

    for {column, type} <- @columns, Atom.to_string(column) not in have do
      execute("ALTER TABLE mice ADD COLUMN #{column} #{type}")
    end
  end

  def down do
    have = existing()

    for {column, _type} <- @columns, Atom.to_string(column) in have do
      execute("ALTER TABLE mice DROP COLUMN #{column}")
    end
  end

  defp existing do
    %{rows: rows} = repo().query!("SELECT name FROM pragma_table_info('mice')")
    List.flatten(rows)
  end
end
