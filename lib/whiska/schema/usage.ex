defmodule Whiska.Schema.Usage do
  @moduledoc """
  What one turn cost, one ledger line of it: the mouse's own row for the turn,
  or one agent it sent. Recorded by the owl at collection, from the transcript
  the doorstep entry names (ADR-next-usage-is-recorded-at-collection), and kept
  like every other record (ADR-0007).

  `transcript` and `turn_started_at` name the turn, as the transcript wrote its
  start. A second entry for the same turn reads it further, so it marks the
  rows already there `replaced` rather than adding to them.
  """

  use Ecto.Schema

  @scopes ~w(mouse agent)

  schema "usage" do
    belongs_to(:question, Whiska.Schema.Question)

    field(:scope, :string)
    field(:label, :string)
    field(:type, :string)
    field(:model, :string)
    field(:effort, :string)
    field(:input, :integer)
    field(:cache_writes, :integer)
    field(:cache_reads, :integer)
    field(:output, :integer)
    field(:steps, :integer)
    field(:tool_uses, :integer)
    field(:seconds, :integer)
    field(:floor, :boolean)
    field(:api_errors, :integer)
    field(:transcript, :string)
    field(:turn_started_at, :string)
    field(:replaced, :boolean, default: false)
  end

  def scopes, do: @scopes
end
