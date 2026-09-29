defmodule Whiska.Test.HomeGuard do
  @moduledoc """
  The backstop that stops the reported bug happening twice.

  `test_helper.exs` points the whiska home and the user home at a temp folder,
  but a test can still put one back wrong — deleting the setting rather than
  restoring it is what emptied the person's real open-houses record. So after
  every test this formatter re-checks every path Whiska writes to outside a
  repo, says where in the run it went wrong, puts the safe values back so the
  rest of the run stays isolated, and fails the run at exit. A leak is a
  failure, never a warning nobody reads.
  """
  use GenServer

  alias Whiska.Test.RealHome

  @impl true
  def init(_opts) do
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
