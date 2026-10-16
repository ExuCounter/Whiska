defmodule Whiska.Migrations.V031QuestionReply do
  @moduledoc """
  Whether a question is its mouse's reply to a letter or an answer, left while
  work the mouse started before that line still ran (ADR-0052), so it is
  recorded closed and waits on nobody.
  """

  use Ecto.Migration

  def change do
    alter table(:questions) do
      add(:reply, :boolean, default: false, null: false)
    end
  end
end
