defmodule Whiska.Migrations.V021ReportHooted do
  @moduledoc """
  When the owl last hooted about a finished report (ADR-0062).

  A finished report is never delivered any more (ADR-0009): it is closed as it
  is collected, hooted once, and its branch reminded while its work waits to
  land. `hooted_at` is nil until that first hoot, and moves on with each
  reminder.

  Every report already in the house was told, or was about to be, under the
  older rule: it is closed, and counts as hooted when it was sent, else when it
  was asked, so an upgrade raises no hoot for any of them.
  """

  use Ecto.Migration

  def change do
    alter table(:questions) do
      add(:hooted_at, :utc_datetime)
    end

    execute(
      "UPDATE questions SET hooted_at = COALESCE(sent_at, asked_at) WHERE kind = 'done'",
      "SELECT 1"
    )

    execute(
      "UPDATE questions SET status = 'closed' WHERE kind = 'done' AND status IN ('open', 'sent')",
      "SELECT 1"
    )
  end
end
