defmodule Whiska.Migrations.V003Delivery do
  @moduledoc """
  What delivery needs that collection did not.

  The house learns its main session from `whiska start`, which records the pane
  it was run from (ADR-0020); that is the whole of the `house` table — one row
  per house, holding the one thing about the house that is not a mouse or a
  question. `sent_at` on a question is when it was delivered, which is what
  makes "one open, unanswered question sitting there" (ADR-0008) a fact on
  disk rather than a memory the owl loses on restart. The new `superseded`
  status is a plain string checked in `Whiska.Storage`.
  """

  use Ecto.Migration

  def change do
    create table(:house) do
      add(:main_pane, :string)
      add(:started_at, :utc_datetime)
    end

    alter table(:questions) do
      add(:sent_at, :utc_datetime)
    end
  end
end
