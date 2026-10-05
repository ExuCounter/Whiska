defmodule Whiska.Test.HomeGuard do
  @moduledoc """
  The guard that keeps the suite out of the person's own home.

  After every test it re-checks every path Whiska writes to outside a repo. On
  a path that has fallen inside the person's home it names where in the run it
  noticed, puts the safe settings back so the rest of the run stays isolated,
  and fails the run at exit — a leak is a failure, never a warning nobody
  reads. `test_helper.exs` supplies the safe settings; `Whiska.Test.RealHome`
  is the check.
  """

  use GenServer

  alias Whiska.Test.RealHome

  @doc """
  Wait until the guard has checked every test that has finished so far. A
  test that moves a home on purpose calls this first, so the check for the
  test before it never reads the moved setting.
  """
  def sync, do: GenServer.call(__MODULE__, :sync)

  @impl true
  def init(_opts) do
    Process.register(self(), __MODULE__)

    {:ok,
     %{
       home: Application.get_env(:whiska, :home),
       user_home: Application.get_env(:whiska, :user_home),
       reported: false
     }}
  end

  @impl true
  def handle_cast({:test_finished, test}, state) do
    case RealHome.violations() do
      [] -> {:noreply, state}
      violations -> {:noreply, report(violations, test, state)}
    end
  end

  def handle_cast(_event, state), do: {:noreply, state}

  @impl true
  def handle_call(:sync, _from, state), do: {:reply, :ok, state}

  defp report(violations, test, state) do
    restore(state)

    IO.puts(:stderr, """

    #{IO.ANSI.red()}A test left Whiska pointing inside the person's own home.#{IO.ANSI.reset()}
      noticed while reporting #{inspect(test.module)}.#{test.name}
    #{Enum.map_join(violations, "\n", fn {name, path} -> "  #{name} → #{path}" end)}

    Restore the setting you overrode — put the previous value back, never
    Application.delete_env/2, which drops the one test_helper.exs set.
    The safe values are back for the rest of the run; this run still fails.
    """)

    unless state.reported, do: System.at_exit(fn _ -> exit({:shutdown, 1}) end)
    %{state | reported: true}
  end

  defp restore(state) do
    Application.put_env(:whiska, :home, state.home)
    Application.put_env(:whiska, :user_home, state.user_home)
  end
end
