defmodule Whiska.Migrations.V018MergeRequestReads do
  @moduledoc """
  What the owl last read of each mouse's merge request on its forge, one row
  per mouse, and who left a question.

  A row is written by the owl's read and nothing else; a merge request that
  has never been read has none. `seen_note_id` is the cursor: a comment at or
  below it never counts again, across restarts and sleeps alike.

  `asked_by` is `owl` on a question the owl itself left about a merge request,
  nil on every question a mouse asked, which is all of them before this.
  """

  use Ecto.Migration

  def change do
    create table(:merge_request_reads, primary_key: false) do
      add(:mouse_id, references(:mice, column: :mouse_id, type: :string), primary_key: true)
      add(:url, :string, null: false)
      add(:state, :string)
      add(:head_sha, :string)
      add(:pipeline_id, :integer)
      add(:pipeline, :string)
      add(:threads_open, :integer, default: 0, null: false)
      add(:notes_count, :integer)
      add(:forge_updated_at, :string)
      add(:ready, :boolean, default: false, null: false)
      add(:seen_note_id, :integer)
      add(:seen_failed_pipeline_id, :integer)
      add(:missing_reads, :integer, default: 0, null: false)
      add(:read_at, :utc_datetime)
      add(:unread_since, :utc_datetime)
      add(:unread_reason, :string)
      add(:asked_at, :utc_datetime)
    end

    alter table(:questions) do
      add(:asked_by, :string)
    end
  end
end
