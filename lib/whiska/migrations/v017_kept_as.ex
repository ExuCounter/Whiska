defmodule Whiska.Migrations.V017KeptAs do
  @moduledoc """
  The name a mouse's kept spec, build plan, research document and report share
  in `.whiska/specs/` (ADR-0063), so they are found without a header in the
  file. Nil until the first is kept; one kept before this is named on the
  record when the house opens and strips its header.
  """

  use Ecto.Migration

  def change do
    alter table(:mice) do
      add(:kept_as, :string)
    end
  end
end
