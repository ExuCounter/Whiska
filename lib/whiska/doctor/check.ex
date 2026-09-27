defmodule Whiska.Doctor.Check do
  @moduledoc """
  One finding from `whiska doctor`.

  Three statuses, drawn on one line: **fail** means a question from a mouse in
  this repo would be lost or never written — a hook not wired, a binary that
  cannot serve it, a house that will not open. **warn** means degraded but
  nothing is lost — the owl is down and entries are waiting on the doorstep, a
  mouse record no longer matches the world. **ok** is ok.

  A failing or warning check carries the exact command that fixes it, when
  there is one. The doctor prints it; it never runs it.
  """

  @enforce_keys [:status, :name, :detail]
  defstruct [:status, :name, :detail, :fix]

  @type status :: :ok | :warn | :fail

  @type t :: %__MODULE__{
          status: status(),
          name: String.t(),
          detail: String.t(),
          fix: String.t() | nil
        }

  @doc false
  def ok(name, detail), do: %__MODULE__{status: :ok, name: name, detail: detail}

  @doc false
  def warn(name, detail, fix \\ nil),
    do: %__MODULE__{status: :warn, name: name, detail: detail, fix: fix}

  @doc false
  def fail(name, detail, fix \\ nil),
    do: %__MODULE__{status: :fail, name: name, detail: detail, fix: fix}
end
