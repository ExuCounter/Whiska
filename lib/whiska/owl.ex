defmodule Whiska.Owl do
  @moduledoc """
  The one always-awake presence per machine (ADR-0001).

  The owl is a supervisor holding one `Whiska.Owl.House` per open house, each
  supervised independently: one project's house crashing and restarting is
  invisible to every other project's. It is the only thing that can see across
  all of them, which is what `open_houses/0` is for.

  Opening and shutting only change whether a house's lights are on (ADR-0003).
  Nothing here ever creates or destroys a house on disk.

  This slice runs the owl in the foreground (`whiska owl`) with the houses to
  open named on the command line; `launchd` supervision and `whiska start`/`stop`
  reaching it over a socket come later.
  """

  use Supervisor

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

  @doc "Open a house, or return the one already open for that checkout."
  @spec open_house(Path.t()) :: {:ok, pid()} | {:error, term()}
  def open_house(main_checkout) do
    main = Path.expand(main_checkout)

    case DynamicSupervisor.start_child(@houses, {__MODULE__.Opener, main}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, _} = error -> error
    end
  end

  @doc "Shut a house: its process stops, its database and records stay."
  @spec shut_house(Path.t()) :: :ok | {:error, :shut}
  def shut_house(main_checkout) do
    with {:ok, pid} <- house(main_checkout) do
      DynamicSupervisor.terminate_child(@houses, pid)
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
