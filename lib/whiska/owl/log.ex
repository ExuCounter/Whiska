defmodule Whiska.Owl.Log do
  @moduledoc """
  The one place the owl writes a line to its log (`~/.whiska/owl.log`, which is
  the owl's stderr).

  Every line starts with the local time. The log used to have none, so a stall
  could be seen in it and never placed: a nine-minute hold was only ever dated
  from other records.
  """

  @doc "Write `message` as one log line, stamped with the local time."
  @spec line(String.t()) :: :ok
  def line(message), do: IO.puts(:stderr, "#{stamp()} #{message}")

  defp stamp do
    {{year, month, day}, {hour, minute, second}} = :calendar.local_time()

    :io_lib.format("~4..0w-~2..0w-~2..0w ~2..0w:~2..0w:~2..0w", [
      year,
      month,
      day,
      hour,
      minute,
      second
    ])
    |> IO.iodata_to_binary()
  end
end
