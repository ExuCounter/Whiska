defmodule Whiska.Backstop do
  @moduledoc """
  The mark a house leaves when its backstop collected what the idle trigger
  should have (ADR-0036).

  The backstop is the last resort, not a working trigger: every entry it picks
  up is one herdr's idle event should have brought a minute earlier. That is
  worth a warning, and for weeks it was not one — the idle trigger had never
  fired at all, and nobody noticed, because the backstop quietly collected
  everything a minute late (ADR-0036).

  The house prints the warning as it happens, and leaves this mark so
  `whiska doctor` can say it afterwards: the doctor is a separate process and
  today reaches the owl only through the process table (ADR-0024/0025 are
  designed, not built), so what it can read is what is on disk.

  A file in the house, `<main-checkout>/.git/whiska/backstop`, beside the
  doorstep and the database — not in `~/.whiska` beside the open-houses record
  (ADR-0039), because this is one house's fact and the doctor is scoped to one
  repo. Keeping it per house means no two houses ever rewrite the same file.
  The shape is ADR-0039's: plain text, written to a temporary name and renamed
  into place, hand-editable and safe to delete.

  One line, `<count> <ISO 8601 timestamp>`, and the count is *since this owl
  opened this house* — `clear/1` runs at open. A mark is therefore always about
  the run that is happening now, never about one that is over.
  """

  @mark ".git/whiska/backstop"

  @typedoc "A house's backstop collections since the owl opened it."
  @type mark :: %{count: pos_integer(), last: DateTime.t()}

  @doc "Where this house's mark lives."
  @spec path(Path.t()) :: Path.t()
  def path(main_checkout), do: Path.join(main_checkout, @mark)

  @doc "The mark, or `nil` when the backstop has collected nothing since the owl opened."
  @spec read(Path.t()) :: mark() | nil
  def read(main_checkout) do
    with {:ok, contents} <- File.read(path(main_checkout)),
         [count, stamp] <- contents |> String.trim() |> String.split(" ", parts: 2),
         {count, ""} when count > 0 <- Integer.parse(count),
         {:ok, last, _offset} <- DateTime.from_iso8601(stamp) do
      %{count: count, last: last}
    else
      _ -> nil
    end
  end

  @doc "Record that the backstop has collected `count` entries, the last of them at `last`."
  @spec record(Path.t(), pos_integer(), DateTime.t()) :: :ok | {:error, File.posix()}
  def record(main_checkout, count, %DateTime{} = last) do
    file = path(main_checkout)
    tmp = file <> ".tmp-#{System.unique_integer([:positive])}"

    with :ok <- File.mkdir_p(Path.dirname(file)),
         :ok <- File.write(tmp, "#{count} #{DateTime.to_iso8601(last)}\n") do
      File.rename(tmp, file)
    end
  end

  @doc "Forget the mark. Clearing one that is not there is fine."
  @spec clear(Path.t()) :: :ok
  def clear(main_checkout) do
    File.rm(path(main_checkout))
    :ok
  end
end
