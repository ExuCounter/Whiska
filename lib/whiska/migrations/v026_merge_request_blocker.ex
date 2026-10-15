defmodule Whiska.Migrations.V026MergeRequestBlocker do
  @moduledoc """
  Why the forge will not merge a mouse's merge request yet, on the owl's row
  for it: `approval`, `conflict`, `draft`, `threads`, `rebase` or
  `blocked`, or nil when nothing does or the pipeline already says it.
  """

  use Ecto.Migration

  def change do
    alter table(:merge_request_reads) do
      add(:blocker, :string)
    end
  end
end
