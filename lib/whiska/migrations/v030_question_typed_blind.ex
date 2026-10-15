defmodule Whiska.Migrations.V030QuestionTypedBlind do
  @moduledoc """
  Whether a question's line was typed while herdr could not say whether the
  person was typing (ADR-0008), so its block can say so.
  """

  use Ecto.Migration

  def change do
    alter table(:questions) do
      add(:typed_blind, :boolean, default: false, null: false)
    end
  end
end
