defmodule Whiska.Migrations.V004Cleanup do
  @moduledoc """
  What cleanup needs: somewhere to say a worktree is gone.

  `removed_at` is the whole of it (ADR-0058). The row stays — ADR-0007's "the
  mouse record is never deleted" is untouched by the worktree half being
  superseded — and this stamp is what makes it permanently inert: a record with
  it set is never swept again, and the folder it named no longer exists.
  """

  use Ecto.Migration

  def change do
    alter table(:mice) do
      add(:removed_at, :utc_datetime)
    end
  end
end
