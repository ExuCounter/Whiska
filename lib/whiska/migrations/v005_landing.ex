defmodule Whiska.Migrations.V005Landing do
  @moduledoc """
  Somewhere to say a branch has landed (ADR-0064).

  `landed_at` is when Whiska first saw this mouse's branch merged into the
  base. It is stamped while the worktree still stands, or from the branch ref
  alone once it has gone, and it is what lets a question the mouse left waiting
  settle rather than orphan: the merge was the answer.
  """

  use Ecto.Migration

  def change do
    alter table(:mice) do
      add(:landed_at, :utc_datetime)
    end
  end
end
