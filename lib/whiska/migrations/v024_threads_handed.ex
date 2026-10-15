defmodule Whiska.Migrations.V024ThreadsHanded do
  @moduledoc """
  The open threads the owl has counted as review on a merge request, by
  thread id, as JSON. An open thread counts once whatever its age, and one
  already counted only again through a new comment in it (ADR-0060).
  """

  use Ecto.Migration

  def change do
    alter table(:merge_request_reads) do
      add(:threads_handed, :text)
    end
  end
end
