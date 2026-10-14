defmodule Whiska.Migrations.V016BuiltFrom do
  @moduledoc """
  The question a build mouse was spawned from (`whiska spawn --from`), so the
  sniff mouse that asked it is taken down once its build lands (ADR-0074).
  Nil for every mouse already in the house: which of them came from a
  proposal is not known.
  """

  use Ecto.Migration

  def change do
    alter table(:mice) do
      add(:built_from, :integer)
    end
  end
end
