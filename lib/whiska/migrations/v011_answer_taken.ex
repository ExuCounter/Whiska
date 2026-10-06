defmodule Whiska.Migrations.V011AnswerTaken do
  @moduledoc """
  Somewhere to say an answer reached its mouse, and how hard the owl tried
  (ADR-0080).

  `taken_at` is when the mouse's own `UserPromptSubmit` hook handed the answer
  over: the proof of delivery. `rung_at` is the last doorbell, `rings` how many
  the owl rang after `reply`'s own, and `stale_at` when the owl gave up and
  told the person the answer was not taken.

  An answer given before this migration was typed whole into the pane, which
  was its delivery, so it is recorded as taken when it was sent.
  """

  use Ecto.Migration

  def change do
    alter table(:questions) do
      add(:taken_at, :utc_datetime)
      add(:rung_at, :utc_datetime)
      add(:rings, :integer, default: 0, null: false)
      add(:stale_at, :utc_datetime)
    end

    execute(
      "UPDATE questions SET taken_at = COALESCE(sent_at, asked_at) WHERE status = 'answered'",
      "SELECT 1"
    )
  end
end
