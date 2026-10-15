defmodule Whiska.Migrations.V028ThreadsAnswered do
  @moduledoc """
  How many of a merge request's open threads end on the account's own word,
  on the owl's row for it: they wait on the reviewer, not on the person.
  """

  use Ecto.Migration

  def change do
    alter table(:merge_request_reads) do
      add(:threads_answered, :integer, default: 0, null: false)
    end
  end
end
