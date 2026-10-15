defmodule Whiska.Test.Unique do
  @moduledoc """
  A name for a scratch directory under the system's temp dir that no other
  `mix test` can also pick.

  `System.unique_integer/1` restarts at the same numbers in every VM, so two
  suites running at once, or one finding what a killed run left behind, would
  share a directory and trip over each other's repos.
  """

  @doc "A short random name, safe in a path."
  def id, do: 6 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
end
