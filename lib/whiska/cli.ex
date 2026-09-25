defmodule Whiska.CLI do
  @moduledoc """
  The `whiska` binary.

  v0.0.1 is a plain CLI built with `mix escript.build`, not the owl (ADR-0030).
  The `PreToolUse` hook invokes it fresh on every tool call: it opens SQLite,
  makes one decision, and exits. No supervision tree — that arrives with the owl
  in a later slice (ADR-0001).
  """

  alias Whiska.Hook.PreToolUse
  alias Whiska.Layout
  alias Whiska.Marker
  alias Whiska.Storage

  @version Mix.Project.config()[:version]

  @usage """
  Usage: whiska <command>

    hook pre-tool-use    Decide one Claude Code PreToolUse event. Reads the
                         event payload as JSON on stdin; prints a deny decision
                         as JSON on stdout, or nothing at all to allow.

    mode                 Print this mouse's mode.
    mode build|sniff     Set it. A build mouse makes changes, confined to its
                         own worktree. A sniff mouse investigates and reports,
                         and may not write anything at all.

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
  def run(argv, cwd \\ nil)

  def run(["hook", "pre-tool-use"], _cwd), do: hook()

  def run(["mode"], cwd), do: with_mouse(cwd, &show_mode/2)

  def run(["mode", mode], cwd) when mode in ["build", "sniff"],
    do: with_mouse(cwd, &set_mode(&1, &2, mode))

  def run(["mode", other], _cwd) do
    IO.puts(:stderr, "whiska: #{other} is not a mode — expected build or sniff.")
    1
  end

  def run(["--version"], _cwd), do: say(@version)
  def run(["-v"], _cwd), do: say(@version)
  def run(["--help"], _cwd), do: say(String.trim_trailing(@usage))
  def run(["help"], _cwd), do: say(String.trim_trailing(@usage))

  def run(_argv, _cwd) do
    IO.write(:stderr, @usage)
    1
  end

  defp say(message) do
    IO.puts(message)
    0
  end

  # Every mouse-scoped command needs the same three things: where we are, who
  # this mouse is, and an open house. `whiska mode` run in a worktree Whiska has
  # never seen mints the id there and then, exactly as the hook would.
  defp with_mouse(cwd, work) do
    cwd = cwd || File.cwd!()

    with {:ok, layout} <- Layout.resolve(cwd),
         {:ok, mouse_id} <- Marker.read_or_mint(layout.worktree_root),
         {:ok, handle} <- Storage.open(layout.main_checkout) do
      try do
        Storage.record_mouse(%{
          mouse_id: mouse_id,
          path: layout.worktree_root,
          branch: layout.branch_label
        })

        work.(mouse_id, layout)
      after
        Storage.close(handle)
      end
    else
      {:error, :not_in_worktree} ->
        IO.puts(
          :stderr,
          """
          whiska: not inside a worktree.

          Whiska tracks a mouse per worktree, laid out under worktrees/<branch>/.
          Run this from inside one.
          """
          |> String.trim()
        )

        1

      other ->
        IO.puts(:stderr, "whiska: could not reach this repo's house (#{inspect(other)}).")
        1
    end
  end

  defp show_mode(mouse_id, layout) do
    case Storage.mode(mouse_id) do
      {:ok, mode} ->
        say("#{mode}  (#{layout.branch_label})")

      {:error, reason} ->
        IO.puts(:stderr, "whiska: could not read the mode (#{inspect(reason)}).")
        1
    end
  end

  defp set_mode(mouse_id, layout, mode) do
    case Storage.set_mode(mouse_id, mode) do
      {:ok, _} ->
        say("#{layout.branch_label} is now a #{mode} mouse.")

      {:error, reason} ->
        IO.puts(:stderr, "whiska: could not set the mode (#{inspect(reason)}).")
        1
    end
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
