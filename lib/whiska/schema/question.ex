defmodule Whiska.Schema.Question do
  @moduledoc """
  A message a mouse sends when it finishes a turn.

  Most enter the delivery queue and wait for an answer; a `done` report never
  does: it is closed as it is collected, and hooted (see CONTEXT.md). Answers are keyed to a
  question's id rather than a branch (ADR-0005), which is what stops an answer
  landing on whichever question Whiska happened to guess.

  Rows are written by collection (ADR-0036): the owl reads a doorstep entry,
  classifies it by its marker (ADR-0009), and records it here.
  """

  use Ecto.Schema

  # `open` waits in the queue; `sent` has been delivered and waits for its
  # answer (ADR-0008). `closed` is a `done` report, closed as it is collected
  # (ADR-0009), or a question closed by hand. `settled` is one its mouse's branch landed on
  # with nothing left alive to answer to: the merge was the answer (ADR-0064).
  # `orphaned` is a question nothing can act on any more and nothing answered
  # either — its mouse died (ADR-0026) or its worktree is gone (ADR-0036) with
  # the work still not landed. `superseded` is a question its own mouse moved
  # past by asking a newer one.
  @statuses ~w(open sent answered settled orphaned closed superseded)
  # `unmarked` is a turn that ended with no marker at all, which is delivered
  # like a question but recorded as such (ADR-0009).
  @kinds ~w(needs-decision done unmarked)

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
    field(:sent_at, :utc_datetime)
    field(:answer, :string)
    field(:taken_at, :utc_datetime)
    field(:rung_at, :utc_datetime)
    field(:rings, :integer, default: 0)
    field(:stale_at, :utc_datetime)
    field(:answered_at, :utc_datetime)
    field(:spec_sent, :boolean, default: false)
    field(:keeps_slot, :boolean, default: false)
    # A mouse's reply to a letter that superseded what held the slot: it goes
    # next once the slot is free, and holds none (ADR-0008).
    field(:goes_next, :boolean, default: false)
    # When the owl last hooted about a finished report: its finish hoot, then
    # each reminder (ADR-0062). Nil while the finish hoot is still owed.
    field(:hooted_at, :utc_datetime)
    # When a finished report's line was typed into the main session, once
    # nothing waited on the person (ADR-0008). Nil while it is still owed.
    field(:typed_at, :utc_datetime)
    # `owl` on a question the owl asked itself about a merge request; nil on a
    # mouse's.
    field(:asked_by, :string)
  end

  @doc "The statuses a question moves through."
  def statuses, do: @statuses

  @doc "Whether the owl asked `question` itself, so it is not its mouse's word."
  @spec owls?(%__MODULE__{}) :: boolean()
  def owls?(%__MODULE__{asked_by: asked_by}), do: asked_by == "owl"

  @doc "A question's kind is purely the mouse's own marker (ADR-0009)."
  def kinds, do: @kinds
end
