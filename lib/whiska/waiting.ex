defmodule Whiska.Waiting do
  @moduledoc """
  Everything waiting on the person, on the whole machine — one entry per thing,
  oldest first.

  `whiska questions` answers "what is waiting *here*"; this answers "what is
  waiting *anywhere*", by reading every house in the open-houses record
  (ADR-0039) rather than only the one the command was run in. Two sources per
  house, the same two `Whiska.Questions` uses: its open and sent questions
  (ADR-0008), and the entries still sitting uncollected on its doorstep
  (ADR-0036), which the database cannot see at all.

  Each entry carries the mouse's herdr pane, because a mouse is a herdr pane
  (ADR-0020) and that is the address `whiska reply` types into. It is not where
  `whiska jump` goes: a jump lands on the house's main session (ADR-0043),
  which `house_for/2` and `main_session/1` are here to find.

  ## The record without an owl

  `Whiska.OpenHouses.open/2` refuses to call a house open while no owl is in the
  process table, and the statusline's headcount is right to use it: a house
  nothing collects cannot gain fresh questions. This reads the record with
  `read/1` instead. Nothing here claims a house is open — ADR-0039's own words
  for the record are that it "only says which repos to look in", and a question
  already recorded, or an entry already on a doorstep, is waiting on the person
  whether or not anything is awake to collect it. A dead owl is exactly when
  this listing matters most.

  Nothing here writes, and no house is created: a recorded checkout that has
  gone, or that has no database yet, is simply empty.
  """

  alias Whiska.Doorstep
  alias Whiska.Mice
  alias Whiska.OpenHouses
  alias Whiska.Question.Marker
  alias Whiska.Schema.Mouse
  alias Whiska.Schema.Question
  alias Whiska.Storage

  # What a listing line has room for, and what a statusline segment would.
  @pointer_max 60

  @typedoc """
  One thing waiting on the person. `id` is the question id, or `nil` for
  something still on the doorstep — it has no id until the owl collects it.
  `status` is `open`, `sent` or `doorstep`; `kind` is the mouse's own marker
  (ADR-0009). `pane` is `nil` when the house has no pane recorded for the mouse.
  """
  @type entry :: %{
          repo: String.t(),
          main_checkout: Path.t(),
          branch: String.t(),
          id: pos_integer() | nil,
          kind: String.t(),
          status: String.t(),
          pointer: String.t(),
          age_s: non_neg_integer(),
          pane: String.t() | nil
        }

  @doc """
  Every waiting entry across every recorded house, oldest first.

  Options: `:open_houses`, the record's path (the real one unless pinned);
  `:now`, the instant ages are measured from.
  """
  @spec list(keyword()) :: [entry()]
  def list(opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    opts
    |> houses()
    |> Enum.flat_map(&house(&1, now: now))
    |> Enum.sort_by(& &1.age_s, :desc)
  end

  @doc """
  One house's waiting entries: its open and sent questions, then whatever is
  still on its doorstep. Oldest first within the house.
  """
  @spec house(Path.t(), keyword()) :: [entry()]
  def house(main_checkout, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    main = Path.expand(main_checkout)
    doorstep = Doorstep.waiting(main)

    entries =
      if File.exists?(Storage.database_path(main)) do
        with_house(main, fn ->
          Enum.map(Storage.questions(), &from_question(&1, main, now)) ++
            Enum.map(doorstep, fn {_file, e} -> from_doorstep(e, main, now, &pane_of/1) end)
        end)
      else
        Enum.map(doorstep, fn {_file, e} -> from_doorstep(e, main, now, fn _ -> nil end) end)
      end

    case entries do
      list when is_list(list) -> Enum.sort_by(list, & &1.age_s, :desc)
      :unreadable -> []
    end
  end

  @doc """
  Has this house anything waiting on the person?

  The statusline's own question (ADR-0027's elsewhere segment), asked here so
  the two can never disagree about what "waiting" means.
  """
  @spec waiting?(Path.t()) :: boolean()
  def waiting?(main_checkout), do: house(main_checkout) != []

  @doc """
  Which house a name given to `whiska jump` means: its own repo, or the repo a
  branch's mouse is working in.

  Searched across every recorded house, since a branch name says nothing about
  which project it belongs to. A repo of that name wins — it is the plainer
  reading of a bare word, and a branch that shares a repo's name is still
  reachable by standing in it. Dead mice do not name a house (ADR-0026): their
  work is over, and their house may have nothing to do with the person now.
  """
  @spec house_for(String.t(), keyword()) :: {:ok, Path.t()} | {:error, :no_such_target}
  def house_for(name, opts \\ []) do
    houses = houses(opts)

    cond do
      main = Enum.find(houses, &(Path.basename(&1) == name)) -> {:ok, main}
      main = Enum.find(houses, &(mouse_on(&1, name) != nil)) -> {:ok, main}
      true -> {:error, :no_such_target}
    end
  end

  @doc """
  The pane a jump into this house lands on: its main session, as `whiska start`
  recorded it (ADR-0043), or `nil` when it has none — no `whiska start` has been
  run there, or the house cannot be read.
  """
  @spec main_session(Path.t()) :: String.t() | nil
  def main_session(main_checkout) do
    main = Path.expand(main_checkout)

    if File.exists?(Storage.database_path(main)) do
      case with_house(main, fn -> Storage.main_pane() end) do
        pane when is_binary(pane) -> pane
        _none -> nil
      end
    end
  end

  defp mouse_on(main, branch) do
    main = Path.expand(main)

    if File.exists?(Storage.database_path(main)) do
      case with_house(main, fn -> Enum.find(Storage.alive_mice(), &(&1.branch == branch)) end) do
        %Mouse{} = mouse -> mouse
        _unreadable -> nil
      end
    end
  end

  # The recorded houses, read rather than `open/2` — see the moduledoc.
  defp houses(opts) do
    opts
    |> Keyword.get_lazy(:open_houses, &OpenHouses.path/0)
    |> OpenHouses.read()
  end

  # A house that will not open, or will not answer, is not an error worth
  # stopping a machine-wide listing for; it is one repo's problem, and `whiska
  # doctor` is where it is explained. This is the one place that has to be said
  # out loud: a per-repo command may fail loudly for its own repo, but every
  # other house's questions must still be listable when one database is corrupt,
  # locked or mid-migration. Opening can fail by returning, and querying can
  # fail by raising or exiting (`DBConnection` does both), so both are caught.
  defp with_house(main, work) do
    try do
      case Storage.open(main) do
        {:ok, handle} ->
          try do
            work.()
          after
            Storage.close(handle)
          end

        {:error, _} ->
          :unreadable
      end
    catch
      :error, _ -> abandon(main)
      :exit, _ -> abandon(main)
    end
  end

  # `Storage.open/1` migrates as it opens, so a database that is corrupt or
  # locked raises from inside the open — after the Repo process is already up.
  # Left running it would be found as `{:already_started, _}` by the *next*
  # house, turning one bad repo into every repo. So the connection is shut down
  # here before moving on.
  defp abandon(main) do
    case Process.whereis(Whiska.Repo) do
      nil -> :ok
      pid -> Storage.close(pid)
    end

    warn(main)
    :unreadable
  end

  # Said once, on stderr, so a listing that silently skipped a repo cannot be
  # mistaken for that repo being quiet. `whiska doctor` is where it is explained.
  defp warn(main) do
    IO.puts(
      :stderr,
      "whiska: could not read #{Path.basename(main)}'s house — skipping it. " <>
        "Run `whiska doctor` in #{main}."
    )
  end

  defp from_question(%Question{} = q, main, now) do
    %{
      repo: Path.basename(main),
      main_checkout: main,
      branch: branch(q),
      id: q.id,
      kind: q.kind,
      status: q.status,
      pointer: Marker.pointer(q.text),
      age_s: max(DateTime.diff(now, q.asked_at, :second), 0),
      pane: pane_of(q.mouse)
    }
  end

  defp from_doorstep(entry, main, now, pane) do
    %{
      repo: Path.basename(main),
      main_checkout: main,
      branch: entry.branch,
      id: nil,
      kind: Marker.classify(entry.text),
      status: "doorstep",
      pointer: Marker.pointer(entry.text),
      age_s: max(DateTime.diff(now, entry.stamped_at, :second), 0),
      pane: pane.(entry.mouse_id)
    }
  end

  defp pane_of(%Mouse{pane: pane}), do: pane
  defp pane_of(mouse_id) when is_binary(mouse_id), do: pane_of(Storage.mouse(mouse_id))
  defp pane_of(_), do: nil

  defp branch(%Question{mouse: %Mouse{branch: branch}}) when is_binary(branch), do: branch
  defp branch(%Question{mouse_id: mouse_id}), do: mouse_id

  @doc """
  The plain-text listing: one line per entry, columns lined up, oldest first.

  Deliberately one line each rather than a count — this is the list you scan
  before deciding where to go, and ADR-0027's "a count for many" is about a
  statusline segment, not about a command whose whole job is the list.
  """
  @spec render([entry()]) :: String.t()
  def render([]), do: "🦉 Nothing needs you · the owl delivers when something does"

  def render(entries) do
    rows = Enum.map(entries, &row/1)
    columns = [:repo, :branch, :what, :age, :ref, :pane]

    widths =
      Map.new(columns, fn c ->
        {c, rows |> Enum.map(&String.length(Map.fetch!(&1, c))) |> Enum.max()}
      end)

    Enum.map_join(rows, "\n", fn row ->
      columns
      |> Enum.map_join("  ", &String.pad_trailing(Map.fetch!(row, &1), widths[&1]))
      |> String.trim_trailing()
    end)
  end

  defp row(entry) do
    %{
      repo: entry.repo,
      branch: entry.branch,
      what: what(entry),
      age: Mice.format_uptime(entry.age_s),
      ref: if(entry.id, do: "##{entry.id}", else: "doorstep"),
      pane: entry.pane || "no pane"
    }
  end

  # The words `whiska questions` already uses for a kind, plus the pointer the
  # mouse wrote after its own marker when there is one.
  defp what(%{kind: kind, pointer: pointer}) do
    case String.trim(pointer) do
      "" -> Whiska.Questions.verb(kind)
      p -> "#{Whiska.Questions.verb(kind)}: #{clip(p)}"
    end
  end

  defp clip(text) do
    if String.length(text) > @pointer_max,
      do: String.slice(text, 0, @pointer_max - 1) <> "…",
      else: text
  end

  @doc """
  The same entries as JSON — an array of objects, for a Raycast script or
  anything else that would rather not parse columns. An empty list is `[]`.
  """
  @spec json([entry()]) :: String.t()
  def json(entries) do
    JSON.encode!(
      Enum.map(entries, fn e ->
        %{
          "repo" => e.repo,
          "main_checkout" => e.main_checkout,
          "branch" => e.branch,
          "id" => e.id,
          "kind" => e.kind,
          "status" => e.status,
          "pointer" => e.pointer,
          "age_seconds" => e.age_s,
          "pane" => e.pane
        }
      end)
    )
  end
end
