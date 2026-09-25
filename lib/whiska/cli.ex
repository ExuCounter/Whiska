defmodule Whiska.CLI do
  @moduledoc """
  The `whiska` binary.

  v0.0.1 is a plain CLI built with `mix escript.build`, not the owl (ADR-0030).
  The `PreToolUse` hook invokes it fresh on every tool call: it opens SQLite,
  makes one decision, and exits. No supervision tree — that arrives with the owl
  in a later slice (ADR-0001).
  """

  alias Whiska.Hook.PreToolUse

  @version Mix.Project.config()[:version]

  @usage """
  Usage: whiska <command>

    hook pre-tool-use    Decide one Claude Code PreToolUse event. Reads the
                         event payload as JSON on stdin; prints a deny decision
                         as JSON on stdout, or nothing at all to allow.

    --version            Print the version.
  """

  @doc """
  escript entry point. Halts the VM with the status `run/1` decided on.
  """
  @spec main([String.t()]) :: no_return()
  def main(argv), do: argv |> run() |> System.halt()

  @doc """
  Run one command and return the exit status it deserves, without halting.

  Split out from `main/1` so the real dispatch is directly testable — no
  test-only branch inside the binary's entry point.
  """
  @spec run([String.t()]) :: non_neg_integer()
  def run(["hook", "pre-tool-use"]), do: hook()
  def run(["--version"]), do: say(@version)
  def run(["-v"]), do: say(@version)
  def run(["--help"]), do: say(String.trim_trailing(@usage))
  def run(["help"]), do: say(String.trim_trailing(@usage))

  def run(_) do
    IO.write(:stderr, @usage)
    1
  end

  defp say(message) do
    IO.puts(message)
    0
  end

  defp hook do
    case IO.read(:stdio, :eof) do
      payload when is_binary(payload) -> payload
      _ -> ""
    end
    |> PreToolUse.run()
    |> PreToolUse.encode()
    |> emit()

    # Always 0: the decision travels in the JSON body, not the exit status. A
    # non-zero exit would read to Claude Code as the hook itself having failed.
    0
  end

  defp emit(:none), do: :ok
  defp emit(json), do: IO.puts(json)
end
