defmodule Whiska.Migrations.V029MergeRequestMerging do
  @moduledoc """
  Whether the forge will merge a request by itself (`auto`) or is merging it
  now (`now`), on the owl's row for it.
  """

  use Ecto.Migration

  def change do
    alter table(:merge_request_reads) do
      add(:merging, :string)
    end
  end
end
