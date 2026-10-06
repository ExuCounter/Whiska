defmodule Whiska.Owl do
  @moduledoc """
  The one always-awake presence per machine (ADR-0001).

  The owl is a supervisor holding one `Whiska.Owl.House` per open house, each
  supervised independently: one project's house crashing and restarting is
  invisible to every other project's. It is the only thing that can see across
  all of them, which is what `open_houses/0` is for — for the statusline and
  the doctor to ask, never for one house to reach into another: nothing under
  the owl types into a session that is not its own house's (ADR-0044), and
  into a mouse's pane only to carry on its own died turn (ADR-0067) or ring for
  its own answer (`Whiska.Doorbell`).

  Opening and shutting only change whether a house's lights are on (ADR-0003).
  Nothing here ever creates or destroys a house on disk.

  Which houses are open is also written down, one line each, in the
  open-houses record (`Whiska.OpenHouses`, ADR-0039): added when a house is
  opened, removed when it is shut, and deliberately left in place when the
  whole owl stops — that is what the next `whiska owl` reopens from.

  `whiska owl` runs it: under launchd or systemd with no arguments, opening
  what the record says (ADR-0040), or in the foreground with houses named on
  the command line. `whiska stop` reaching one house over a socket comes later.
  """

  use Supervisor

  alias Whiska.OpenHouses
  alias Whiska.Owl.House

  @registry Whiska.Owl.Registry
  @houses Whiska.Owl.Houses

  @doc """
  Start the owl. Options are passed to every house it opens: `:herdr_socket`,
  `:backstop_ms`, `:resubscribe_ms`.
  """
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    children = [
      {Registry, keys: :unique, name: @registry},
      {DynamicSupervisor, name: @houses, strategy: :one_for_one, extra_arguments: [opts]}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc """
  The pids of the owls running on this machine, from the process table.

  No pidfile and no global socket yet (ADR-0025 is unbuilt), so the process
  table is the only place to look. Shared by `whiska doctor` and the
  statusline so the two cannot disagree about whether the owl is up. When the
  owl's socket exists this asks it instead, and learns which houses are open
  for free.
  """
  @spec pids() :: [pos_integer()]
  def pids do
    # `pgrep -f` matches argv, so `whiska owl install` (or stop, or start)
    # would find itself; the calling process is never an owl.
    self = String.to_integer(System.pid())

    case System.cmd("pgrep", ["-f", "whiska owl"], stderr_to_stdout: true) do
      {out, 0} -> out |> String.split() |> Enum.flat_map(&pid/1) |> Enum.reject(&(&1 == self))
      _ -> []
    end
  rescue
    ErlangError -> []
  end

  defp pid(s) do
    case Integer.parse(s) do
      {n, ""} -> [n]
      _ -> []
    end
  end

  @doc """
  When a running process started, from `ps`.

  The doctor's one way to tell an owl that is merely up from an owl that is up
  and old: a process started before the binary on disk was written is running
  code the person has already replaced (ADR-0038 — the doctor says so and never
  restarts it). Elapsed time rather than a start date, because `ps -o lstart`
  prints a local-time string in the machine's own locale and this needs no
  parsing of either.

  `now` and `etime` are there so the arithmetic can be tested without a process
  of a known age; `nil` for a pid `ps` does not know, or output it cannot read.
  """
  @spec started_at(pos_integer(), DateTime.t(), (pos_integer() -> String.t() | nil)) ::
          DateTime.t() | nil
  def started_at(pid, now \\ DateTime.utc_now(), etime \\ &etime/1) do
    case etime.(pid) do
      text when is_binary(text) ->
        case elapsed(String.trim(text)) do
          nil -> nil
          seconds -> DateTime.add(now, -seconds, :second)
        end

      _unknown ->
        nil
    end
  end

  # `[[dd-]hh:]mm:ss`, which is every width ps prints it in.
  defp elapsed(text) do
    [clock | days] = text |> String.split("-") |> Enum.reverse()
    numbers = Enum.map(days ++ String.split(clock, ":"), &number/1)

    case Enum.reverse(numbers) do
      [seconds, minutes | rest] when is_integer(seconds) and is_integer(minutes) ->
        if Enum.all?(rest, &is_integer/1) do
          hours = Enum.at(rest, 0, 0)
          days = Enum.at(rest, 1, 0)
          seconds + minutes * 60 + hours * 3600 + days * 86_400
        end

      _not_a_clock ->
        nil
    end
  end

  defp number(text) do
    case Integer.parse(text) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp etime(pid) do
    case System.cmd("ps", ["-o", "etime=", "-p", Integer.to_string(pid)], stderr_to_stdout: true) do
      {out, 0} -> out
      _ -> nil
    end
  rescue
    ErlangError -> nil
  end

  @doc """
  Open a house, or return the one already open for that checkout. Either way
  it is in the open-houses record afterwards.
  """
  @spec open_house(Path.t()) :: {:ok, pid()} | {:error, term()}
  def open_house(main_checkout) do
    main = Path.expand(main_checkout)

    with {:ok, pid} <- start_house(main),
         :ok <- OpenHouses.add(main) do
      {:ok, pid}
    end
  end

  defp start_house(main) do
    case DynamicSupervisor.start_child(@houses, {__MODULE__.Opener, main}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, _} = error -> error
    end
  end

  @doc """
  Shut a house: its process stops and it leaves the open-houses record; its
  database and records stay.
  """
  @spec shut_house(Path.t()) :: :ok | {:error, :shut}
  def shut_house(main_checkout) do
    with {:ok, pid} <- house(main_checkout),
         :ok <- DynamicSupervisor.terminate_child(@houses, pid) do
      OpenHouses.remove(Path.expand(main_checkout))
    end
  end

  @doc "The process for an open house."
  @spec house(Path.t()) :: {:ok, pid()} | {:error, :shut}
  def house(main_checkout) do
    case Registry.lookup(@registry, Path.expand(main_checkout)) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :shut}
    end
  end

  @doc "Every open house's main checkout."
  @spec open_houses() :: [Path.t()]
  def open_houses do
    Registry.select(@registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  @doc false
  def via(main_checkout), do: {:via, Registry, {@registry, main_checkout}}

  defmodule Opener do
    @moduledoc false
    # Turns the owl-wide options plus one checkout into a house child spec, so
    # a house restarted by the supervisor comes back with the same options.
    def child_spec(main_checkout) do
      %{
        id: {House, main_checkout},
        start: {__MODULE__, :start_link, [main_checkout]},
        restart: :permanent
      }
    end

    def start_link(owl_opts, main_checkout) do
      owl_opts
      |> Keyword.put(:main_checkout, main_checkout)
      |> Keyword.put(:name, Whiska.Owl.via(main_checkout))
      |> House.start_link()
    end
  end
end
