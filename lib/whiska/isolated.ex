defmodule Whiska.Isolated do
  @moduledoc """
  Run one piece of work where its failure cannot reach the caller.

  Opening a house is the reason this exists. `Repo.start_link` links the repo
  supervisor to whoever starts it, so a database that will not open takes its
  starter down with it — and both hooks have something more important to do than
  read the database. `PreToolUse` has a rule to enforce that never consults it,
  and `Stop` has a mouse's whole final message to leave on the doorstep
  (ADR-0036). Neither may die of a storage problem.

  So the work runs in an *unlinked*, monitored process. Anything it raises,
  exits with, or is killed by comes back as `{:error, reason}`, and work that
  never returns is killed on a deadline rather than hanging the hook.
  """

  @timeout 5_000

  @doc "Run `work`, giving it at most `timeout` milliseconds."
  @spec run((-> result), pos_integer()) :: result | {:error, term()} when result: term()
  def run(work, timeout \\ @timeout) do
    parent = self()
    {pid, ref} = spawn_monitor(fn -> send(parent, {__MODULE__, self(), work.()}) end)

    receive do
      {__MODULE__, ^pid, result} ->
        Process.demonitor(ref, [:flush])
        result

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:error, reason}
    after
      timeout ->
        Process.demonitor(ref, [:flush])
        Process.exit(pid, :kill)
        {:error, :timeout}
    end
  end
end
