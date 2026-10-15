defmodule Whiska.Migrations.V027HouseLetters do
  @moduledoc """
  Letters another repo's main session left in this house (`whiska tell`,
  ADR-0044): which repo sent each, where its file was copied, when it was left,
  and when this house's delivery typed its line, nil until then. Kept like
  every other record (ADR-0007).

  A house an earlier build of this table already migrated, under version 26,
  keeps its table and rows.
  """

  use Ecto.Migration

  def change do
    create_if_not_exists table(:house_letters) do
      add(:from_repo, :string, null: false)
      add(:from_checkout, :string, null: false)
      add(:path, :string, null: false)
      add(:left_at, :utc_datetime, null: false)
      add(:typed_at, :utc_datetime)
    end
  end
end
