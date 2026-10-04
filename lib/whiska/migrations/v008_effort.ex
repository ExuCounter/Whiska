defmodule Whiska.Migrations.V008Effort do
  @moduledoc """
  The rest of a mouse's shape (ADR-0073).

  `effort` is the effort the spawn asked for, nil for the person's own default.
  `ran_on` is the model id the mouse's latest turn actually ran on, read from
  its transcript — what the alias in `model` resolved to, or what Claude Code
  fell back to — nil until a turn has said.
  """

  use Ecto.Migration

  def change do
    alter table(:mice) do
      add(:effort, :string)
      add(:ran_on, :string)
    end
  end
end
