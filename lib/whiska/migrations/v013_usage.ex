defmodule Whiska.Migrations.V013Usage do
  @moduledoc """
  What each turn cost, and two stamps the metrics read
  (ADR-0086).

  `usage` holds one row per ledger line of a collected turn, keyed by its
  question: the mouse's own row for that turn, and one per agent it sent.
  `transcript` and `turn_started_at` say which turn; a later entry for the same
  turn marks the earlier rows `replaced`, so the rows not replaced add up.

  `answered_at` is when the person replied. `spec_sent` marks a question whose
  turn left a new or revised spec. Both stay unset on the questions already in
  the house: when those were answered, and which carried a spec, is not known.
  """

  use Ecto.Migration

  def change do
    create table(:usage) do
      add(:question_id, references(:questions), null: false)
      add(:scope, :string, null: false)
      add(:label, :string)
      add(:type, :string)
      add(:model, :string)
      add(:effort, :string)
      add(:input, :integer, null: false)
      add(:cache_writes, :integer, null: false)
      add(:cache_reads, :integer, null: false)
      add(:output, :integer, null: false)
      add(:steps, :integer, null: false)
      add(:tool_uses, :integer, null: false)
      add(:seconds, :integer)
      add(:floor, :boolean, null: false)
      add(:api_errors, :integer, null: false)
      add(:transcript, :string)
      add(:turn_started_at, :string)
      add(:replaced, :boolean, default: false, null: false)
    end

    create(index(:usage, [:question_id]))
    create(index(:usage, [:transcript, :turn_started_at]))

    alter table(:questions) do
      add(:answered_at, :utc_datetime)
      add(:spec_sent, :boolean, default: false, null: false)
    end
  end
end
