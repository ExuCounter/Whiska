defmodule Whiska.Repo do
  @moduledoc """
  This house's database.

  ADR-0028 keeps storage on SQLite rather than reverting to flat files: real
  queries, no hand-rolled locking, no directory scanning. ADR-0030 opens it
  per-invocation instead of holding it open in a long-lived process — the owl
  will hold the same file open later without the schema changing shape.
  """

  use Ecto.Repo, otp_app: :whiska, adapter: Ecto.Adapters.SQLite3
end
