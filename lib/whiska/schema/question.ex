defmodule Whiska.Schema.Question do
  @moduledoc """
  A message a mouse sends when it finishes a turn.

  Most enter the delivery queue and wait for an answer; a `done` report is closed
  on arrival and never delivered (see CONTEXT.md). Answers are keyed to a
  question's id rather than a branch (ADR-0005), which is what stops an answer
  landing on whichever question Whiska happened to guess.

  v0.0.1 has no rule that writes a meaningful row here — its one rule denies
  rather than asks — but the table carries its final schema from day one so
  nothing changes shape when the owl arrives (ADR-0030).
  """

  use Ecto.Schema

  @statuses ~w(open sent answered orphaned)
  @kinds ~w(needs-decision done)

  schema "questions" do
    belongs_to(:mouse, Whiska.Schema.Mouse,
      foreign_key: :mouse_id,
      references: :mouse_id,
      type: :string
    )

    field(:text, :string)
    field(:kind, :string)
    field(:status, :string, default: "open")
    field(:asked_at, :utc_datetime)
    field(:answer, :string)
  end

  @doc "The statuses a question moves through."
  def statuses, do: @statuses

  @doc "A question's kind is purely the mouse's own marker (ADR-0009)."
  def kinds, do: @kinds
end
