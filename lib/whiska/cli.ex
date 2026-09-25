defmodule Whiska.CLI do
  @moduledoc """
  The `whiska` binary.

  v0.0.1 is a plain CLI built with `mix escript.build`, not the owl (ADR-0030).
  The `PreToolUse` hook invokes it fresh on every tool call: it opens SQLite,
  makes one decision, and exits. No supervision tree — that arrives with the owl
  in a later slice (ADR-0001).
  """

  alias Whiska.Hook.PreToolUse
  alias Whiska.Install
  alias Whiska.Layout
  alias Whiska.Marker
  alias Whiska.Storage

  @version Mix.Project.config()[:version]

  @usage """
  Usage: whiska <command>

    hook pre-tool-use    Decide one Claude Code PreToolUse event. Reads the
                         event payload as JSON on stdin; prints a deny decision
                         as JSON on stdout, or nothing at all to allow.

    init                 Write Whiska's PreToolUse hook into this repo's own
                         .claude/settings.json, so the rules travel with the
                         repo. Safe to re-run.

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

  def run(["init"], cwd), do: init(cwd || File.cwd!())

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

  defp init(repo_root) do
    path = Path.join(repo_root, ".claude/settings.json")
    shim = Path.join(repo_root, Install.shim_path())

    with {:ok, settings} <- read_settings(path),
         merged = Install.merge(settings),
         :ok <- File.mkdir_p(Path.dirname(shim)),
         :ok <- File.write(shim, Install.shim()),
         :ok <- File.chmod(shim, 0o755),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, JSON.encode!(merged) |> reformat()) do
      say(
        """
        Wrote Whiska's PreToolUse hook to .claude/settings.json.

          matcher: #{Install.matcher()}
          command: #{Install.command()}

        The shim it calls went to #{Install.shim_path()}. That is where the Whiska
        binary and the Erlang runtime get resolved, when the hook fires — so
        neither file names anything specific to this machine.

        Check both into git so the rules travel with the repo (ADR-0016):

          git add .claude/settings.json #{Install.shim_path()}
          git commit -m "chore: enable whiska"
        """
        |> String.trim()
      )
    else
      {:error, :unparseable} ->
        IO.puts(
          :stderr,
          """
          whiska: could not parse #{path}.

          Refusing to touch it rather than overwrite settings that might matter.
          Fix the JSON, or move the file aside, and run this again.
          """
          |> String.trim()
        )

        1

      {:error, reason} ->
        IO.puts(:stderr, "whiska: could not write #{path} (#{inspect(reason)}).")
        1
    end
  end

  # A missing file is a fresh install; an unreadable one is not, and must never
  # be silently replaced.
  defp read_settings(path) do
    case File.read(path) do
      {:error, :enoent} ->
        {:ok, %{}}

      {:ok, raw} ->
        case JSON.decode(raw) do
          {:ok, settings} when is_map(settings) -> {:ok, settings}
          _ -> {:error, :unparseable}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # This file is meant to be read and reviewed in a diff before being committed,
  # so it is not left as one long line.
  defp reformat(json) do
    case JSON.decode(json) do
      {:ok, decoded} -> encode_pretty(decoded, 0) <> "\n"
      _ -> json
    end
  end

  defp encode_pretty(value, indent) when is_map(value) and map_size(value) > 0 do
    pad = String.duplicate("  ", indent + 1)

    inner =
      value
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join(",\n", fn {k, v} ->
        "#{pad}#{JSON.encode!(k)}: #{encode_pretty(v, indent + 1)}"
      end)

    "{\n" <> inner <> "\n" <> String.duplicate("  ", indent) <> "}"
  end

  defp encode_pretty(value, indent) when is_list(value) and value != [] do
    pad = String.duplicate("  ", indent + 1)
    inner = Enum.map_join(value, ",\n", &(pad <> encode_pretty(&1, indent + 1)))
    "[\n" <> inner <> "\n" <> String.duplicate("  ", indent) <> "]"
  end

  defp encode_pretty(value, _indent), do: JSON.encode!(value)

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
