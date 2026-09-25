defmodule Whiska.Migrations.V001CreateMiceAndQuestions do
  @moduledoc """
  Both tables, at their final schema, from day one (ADR-0030).

  This lives in `lib/` rather than the conventional `priv/repo/migrations/`
  because an escript has no `priv` directory at runtime — there is no unpacked
  application, just embedded beams. `Whiska.Storage` hands the module straight to
  `Ecto.Migrator`, so this is a real `Ecto.Migration` exactly as ADR-0028 intends,
  just located where a single-binary CLI can still reach it.
  """

  use Ecto.Migration

  def change do
    create table(:mice, primary_key: false) do
      add(:mouse_id, :string, primary_key: true)
      add(:pane, :string)
      add(:path, :string)
      add(:branch, :string)
      add(:mode, :string, null: false, default: "build")
      add(:created_at, :utc_datetime, null: false)
    end

    create table(:questions) do
      add(:mouse_id, references(:mice, column: :mouse_id, type: :string, on_delete: :nothing),
        null: false
      )

      add(:text, :text, null: false)
      add(:kind, :string, null: false)
      add(:status, :string, null: false, default: "open")
      add(:asked_at, :utc_datetime, null: false)
      add(:answer, :text)
    end

    # Delivery walks a house's open questions (ADR-0008) and the sweep cascades a
    # dead mouse's open questions to orphaned (ADR-0007); both read this way.
    create(index(:questions, [:mouse_id]))
    create(index(:questions, [:status]))
  end
end
