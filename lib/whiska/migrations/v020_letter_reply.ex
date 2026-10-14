defmodule Whiska.Migrations.V020LetterReply do
  @moduledoc """
  Somewhere to say a mouse's reply to a letter goes next (ADR-0008).

  `whiska send` supersedes the questions its mouse was waiting on at once and
  frees the slot. When one of them held it, the mouse's reply goes next once
  the slot is free again: `reply_goes_next` on the mouse, the column version
  19 added under another name, carries that from the letter to the mouse's
  next collected message, which spends it, and `goes_next` marks that
  message. The reply holds no slot, so another branch's heir still goes first.
  """

  use Ecto.Migration

  def change do
    rename(table(:mice), :next_keeps_slot, to: :reply_goes_next)

    alter table(:questions) do
      add(:goes_next, :boolean, default: false, null: false)
    end
  end
end
