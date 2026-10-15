defmodule Whiska.Migrations.V023ReportTyped do
  @moduledoc """
  When a finished report's line was typed into the main session (ADR-0008).

  A finished report is typed once nothing waits on the person, and holds
  nothing after (ADR-0008). `typed_at` is nil while its line is still owed.

  Every report already in the house was hooted, or never meant to be typed:
  each counts as typed when it was sent, else hooted, else asked, so an
  upgrade types none of them.
  """

  use Ecto.Migration

  def change do
    alter table(:questions) do
      add(:typed_at, :utc_datetime)
    end

    execute(
      "UPDATE questions SET typed_at = COALESCE(sent_at, hooted_at, asked_at) WHERE kind = 'done'",
      "SELECT 1"
    )
  end
end
