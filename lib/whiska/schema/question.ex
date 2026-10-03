defmodule Whiska.Schema.Question do
  @moduledoc """
  A message a mouse sends when it finishes a turn.

  Most enter the delivery queue and wait for an answer; a `done` report is
  delivered too, then closed at once instead of waiting (see CONTEXT.md). Answers are keyed to a
  question's id rather than a branch (ADR-0005), which is what stops an answer
  landing on whichever question Whiska happened to guess.

  Rows are written by collection (ADR-0036): the owl reads a doorstep entry,
  classifies it by its marker (ADR-0009), and records it here.
  """

  use Ecto.Schema

  # `open` waits in the queue; `sent` has been delivered and waits for its
  # answer (ADR-0008). `closed` is a `done` report closed once sent (ADR-0009),
  # or a question closed by hand. `settled` is one its mouse's branch landed on
  # with nothing left alive to answer to: the merge was the answer (ADR-0063).
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
  end

  @doc "The statuses a question moves through."
  def statuses, do: @statuses

  @doc "A question's kind is purely the mouse's own marker (ADR-0009)."
  def kinds, do: @kinds
end
