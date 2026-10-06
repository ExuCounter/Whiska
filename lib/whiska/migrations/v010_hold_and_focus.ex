defmodule Whiska.Migrations.V010HoldAndFocus do
  @moduledoc """
  Somewhere to say a mouse is on hold, and somewhere to say which mouse a house
  is focused on (ADR-next-the-person-decides-what-reaches-them).

  `held_at` is when the person put this mouse on hold: its next write or shell
  command is refused, nothing of its is delivered, and it is never offered for landing,
  until `resume <branch>` clears the stamp. It is a stamp on the record rather
  than a line of text somewhere because it has to survive an owl restart and
  show wherever the mouse is listed.

  `focus` on the house's one row is the `mouse_id` whose questions alone reach
  this house's main session while it is set. The id, not the branch: identity
  is the marker id (ADR-0002), and the branch is read back for display.

  Away is machine-wide and lives in a file under the whiska home, not here.
  """

  use Ecto.Migration

  def change do
    alter table(:mice) do
      add(:held_at, :utc_datetime)
    end

    alter table(:house) do
      add(:focus, :string)
    end
  end
end
