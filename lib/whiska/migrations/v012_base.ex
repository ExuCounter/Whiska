defmodule Whiska.Migrations.V012Base do
  @moduledoc """
  The branch a mouse's worktree was cut from.

  `whiska shape` records the branch the main checkout is on when it runs in
  the new worktree, and a mouse's branch is measured against that, not
  against the repo's default branch (ADR-0061).

  Nil for every mouse already in the house: where each was cut from is not
  known, and a guess would be a claim. Nil reads as the default branch.
  """

  use Ecto.Migration

  def change do
    alter table(:mice) do
      add(:base, :string)
    end
  end
end
