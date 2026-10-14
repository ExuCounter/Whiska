defmodule Whiska.Schema.MergeRequestRead do
  @moduledoc """
  What the owl last read of one mouse's merge request on its forge (ADR-0087).

  Keyed by the mouse, for the link in `url`: a mouse whose link changes starts
  a row afresh. `state` is nil until a read works, then `open`, `merged`,
  `closed`, or `gone` once the forge has not had it three reads in a row.
  """

  use Ecto.Schema

  @primary_key {:mouse_id, :string, autogenerate: false}

  schema "merge_request_reads" do
    field(:url, :string)
    field(:state, :string)
    field(:head_sha, :string)
    field(:pipeline_id, :integer)
    # running | passed | failed | other, or nil with no pipeline.
    field(:pipeline, :string)
    field(:threads_open, :integer, default: 0)
    field(:notes_count, :integer)
    field(:forge_updated_at, :string)
    field(:ready, :boolean, default: false)
    # The cursor: a comment at or below it never counts.
    field(:seen_note_id, :integer)
    field(:seen_failed_pipeline_id, :integer)
    field(:missing_reads, :integer, default: 0)
    # The last read that worked; and since when, and why, every read has failed.
    field(:read_at, :utc_datetime)
    field(:unread_since, :utc_datetime)
    field(:unread_reason, :string)
    # When the owl asked the person about this merge request closing; cleared
    # when it reads open again.
    field(:asked_at, :utc_datetime)
  end

  @fields ~w(url state head_sha pipeline_id pipeline threads_open notes_count forge_updated_at
             ready seen_note_id seen_failed_pipeline_id missing_reads read_at unread_since
             unread_reason asked_at)a

  @doc false
  def fields, do: @fields
end
