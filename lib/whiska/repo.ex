defmodule Whiska.Repo do
  @moduledoc """
  This house's database.

  ADR-0028 keeps storage on SQLite rather than reverting to flat files: real
  queries, no hand-rolled locking, no directory scanning. The hooks open it
  per-invocation (ADR-0030); each open house holds its own instance of this
  repo for as long as its lights are on (`Whiska.Owl.House`).
  """

  use Ecto.Repo, otp_app: :whiska, adapter: Ecto.Adapters.SQLite3
end
