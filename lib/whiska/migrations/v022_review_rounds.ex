defmodule Whiska.Migrations.V022ReviewRounds do
  @moduledoc """
  A merge request's review rounds, on the owl's row for it.

  `pending` is the review the owl read and has not handed to a mouse yet: the
  new comments, each with its thread, and a failed pipeline, as JSON. The
  `round_` columns say when the owl last woke or started a mouse for one, how,
  and where the branch stood then, so the next round can tell whether that one
  pushed; `rounds_unpushed` counts the rounds in a row that did not. The
  `review_asked_` pair is the owl's own question about the review, as
  `asked_at` is its question about a close.
  """

  use Ecto.Migration

  def change do
    alter table(:merge_request_reads) do
      add(:pending, :text)
      add(:round_at, :utc_datetime)
      add(:round_by, :string)
      add(:round_ref, :string)
      add(:round_head, :string)
      add(:rounds_unpushed, :integer, default: 0, null: false)
      add(:review_asked_at, :utc_datetime)
      add(:review_asked_why, :string)
    end
  end
end
