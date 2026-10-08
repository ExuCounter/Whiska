defmodule Whiska.Delivery.Mode do
  @moduledoc """
  What may reach the person right now (ADR-0079).

  Three things the person sets, each stored where its scope is:

  - **Away** is machine-wide: one file under the whiska home. While it exists
    nothing is delivered to any main session; mice keep working and `inbox`
    keeps listing. No owl is needed to set or clear it.
  - **Focus** is one house's: the `mouse_id` on the house's own row whose
    questions alone reach its main session while it is set.
  - **Held** is one mouse's: `held_at` on its record. Nothing of a held mouse is
    delivered, and its next write or shell command is refused (`Whiska.Rule.Held`).

  The queue is judged against all three before the gate ever sees it
  (ADR-0008, ADR-0047): `next/2` is what the house delivers next, and it is
  the one place that rule lives, so the board, `whiska questions` and the
  owl cannot disagree about why a question is waiting.

  Two exceptions to the one slot follow from it, and both are deliberate. A
  `sent` question whose mouse is held, or is not the focused mouse while a
  focus is on, does not count as holding the slot: a hold or a focus that left
  the queue wedged behind the very question the person set it aside would be
  no hold at all. Such a question stays `sent` — it was delivered, and nothing
  is delivered twice — and once the mode is lifted the queue waits behind the
  oldest `sent` one again, oldest first, as it always has.
  """

  alias Whiska.Delivery.Text
  alias Whiska.OpenHouses
  alias Whiska.Schema.Question
  alias Whiska.Storage

  @typedoc """
  The mode as one house reads it: whether the machine is away, which mouse
  this house focuses on, and which of its mice are held.
  """
  @type t :: %{away?: boolean(), focus: String.t() | nil, held: MapSet.t(String.t())}

  @typedoc "Why a question is not being delivered, or nil."
  @type waits :: nil | :held | :away | {:focus, String.t()}

  @doc "No mode set at all: everything flows."
  @spec none() :: t()
  def none, do: %{away?: false, focus: nil, held: MapSet.new()}

  @doc """
  The mode for the house this process is pointed at. Options: `:away_path`,
  the away file (the real one unless pinned).
  """
  @spec read(keyword()) :: t()
  def read(opts \\ []) do
    %{
      away?: away?(Keyword.get_lazy(opts, :away_path, &away_path/0)),
      focus: Storage.focus(),
      held: Storage.held_ids()
    }
  end

  @doc "Where away is written: `away` under the whiska home, beside the open-houses record."
  @spec away_path(Path.t()) :: Path.t()
  def away_path(home \\ OpenHouses.home()), do: Path.join(home, "away")

  @doc "Is the person away?"
  @spec away?(Path.t()) :: boolean()
  def away?(path \\ away_path()), do: File.exists?(path)

  @doc """
  Go away: nothing is delivered anywhere until `clear_away/1`. Safe to repeat.

  Refused where a symlink sits at the path: the whiska home is writable by a
  build mouse, and a write through a planted link would land in whatever it
  points at.
  """
  @spec set_away(Path.t()) :: :ok | {:error, File.posix() | :symlink}
  def set_away(path \\ away_path()) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :error <-
           :file.read_link(path) |> elem(0) |> then(&if(&1 == :ok, do: :symlink, else: :error)) do
      File.write(path, DateTime.utc_now() |> DateTime.to_iso8601() |> Kernel.<>("\n"))
    else
      :symlink -> {:error, :symlink}
      error -> error
    end
  end

  @doc "Come back. Clearing an away that was never set is fine."
  @spec clear_away(Path.t()) :: :ok | {:error, File.posix()}
  def clear_away(path \\ away_path()) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      error -> error
    end
  end

  @doc """
  The one line `resume <branch>` types into a mouse that stopped because of
  its hold. A fact and a caution, no decision — the same shape as the owl's
  pickup line (ADR-0067), because the session still knows what it did.
  """
  @spec resume_line() :: String.t()
  def resume_line do
    "The hold on this branch is lifted. Carry on from where you stopped, and " <>
      "check what you already did before redoing any of it."
  end

  @doc "May this question reach the person now?"
  @spec deliverable?(Question.t(), t()) :: boolean()
  def deliverable?(%Question{} = question, mode), do: waits(question, mode) == nil

  @doc """
  Why a question is not being delivered: its mouse is held, the person is
  away, or this house focuses on another mouse — in that order, the most
  specific thing the person did first. Nil when nothing stands in its way.
  """
  @spec waits(Question.t(), t()) :: waits()
  def waits(%Question{mouse_id: mouse_id}, mode) do
    cond do
      MapSet.member?(mode.held, mouse_id) -> :held
      mode.away? -> :away
      is_binary(mode.focus) and mode.focus != mouse_id -> {:focus, mode.focus}
      true -> nil
    end
  end

  @doc """
  What goes next, if the main session will have it, out of the house's
  waiting questions (`Whiska.Storage.questions/0`): nothing while a
  deliverable question is sent; otherwise the oldest deliverable finished
  report, else the oldest deliverable open question. A finished report waits
  for the slot, then holds it once sent until the person writes something
  (ADR-0008, notes of 2026-10-06 and 2026-10-08). Oldest
  first, always; newest-first was rejected (a newer question from any mouse
  would jump ahead, and old ones could wait forever).
  """
  @spec next([Question.t()], t()) :: Question.t() | nil
  def next(questions, mode) do
    deliverable = questions |> Enum.filter(&deliverable?(&1, mode)) |> Enum.sort_by(& &1.id)
    open = Enum.filter(deliverable, &(&1.status == "open"))

    cond do
      Enum.any?(deliverable, &(&1.status == "sent")) -> nil
      report = Enum.find(open, &(&1.kind == "done")) -> report
      true -> List.first(open)
    end
  end

  @doc "The id of the sent question holding the slot for deliverable questions, or nil."
  @spec slot([Question.t()], t()) :: pos_integer() | nil
  def slot(questions, mode) do
    questions
    |> Enum.filter(&(&1.status == "sent" and deliverable?(&1, mode)))
    |> Enum.map(& &1.id)
    |> Enum.min(fn -> nil end)
  end

  @doc "How many open questions could be delivered."
  @spec open_count([Question.t()], t()) :: non_neg_integer()
  def open_count(questions, mode) do
    Enum.count(questions, &(&1.status == "open" and deliverable?(&1, mode)))
  end

  @doc """
  What could be delivered behind `question`, finished reports counted apart:
  what a line's `n more finished` and `n more open` say.
  """
  @spec more([Question.t()], t(), Question.t()) :: Text.more()
  def more(questions, mode, %Question{id: id}) do
    {finished, open} =
      questions
      |> Enum.filter(&(&1.status == "open" and &1.id != id and deliverable?(&1, mode)))
      |> Enum.split_with(&(&1.kind == "done"))

    %{finished: length(finished), open: length(open)}
  end
end
