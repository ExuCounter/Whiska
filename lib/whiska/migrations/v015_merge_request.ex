defmodule Whiska.Migrations.V015MergeRequest do
  @moduledoc """
  The merge request the person opened for a mouse's branch, and when.

  Stamped by `whiska merge-request` once "Open a merge request / PR" has
  succeeded, so a later finished line offers what fits an open PR, and the owl
  knows which bases to fetch. Nil for every mouse already in the house: which
  of them had one opened is not known.
  """

  use Ecto.Migration

  def change do
    alter table(:mice) do
      add(:merge_request_at, :utc_datetime)
      add(:merge_request_url, :string)
    end
  end
end
