defmodule Whiska.Migrations.V006Pickup do
  @moduledoc """
  Somewhere to say a turn was in flight, and somewhere to say it was picked up
  (ADR-0065).

  `worked_at` is when herdr last told the owl this mouse's pane had started
  working — the only evidence Whiska holds that a turn began. `picked_up_at`
  is when the owl last typed a line into that pane to carry a died turn on.
  Both outlive the owl, because a turn can die while the owl is restarting and
  a cap that forgets is no cap.
  """

  use Ecto.Migration

  def change do
    alter table(:mice) do
      add(:worked_at, :utc_datetime)
      add(:picked_up_at, :utc_datetime)
    end
  end
end
