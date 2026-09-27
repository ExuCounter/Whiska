defmodule Whiska.CLI do
  @moduledoc """
  The `whiska` binary.

  Built with `mix escript.build`. The hooks invoke it fresh per event (ADR-0030):
  `PreToolUse` opens SQLite, makes one decision, and exits; `Stop` writes one
  doorstep entry and exits. `whiska owl` is the other half — the one supervised
  process per machine (ADR-0001), run in the foreground for now.
  """

  alias Whiska.Hook.PreToolUse
  alias Whiska.Hook.Stop
  alias Whiska.Herdr
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

    hook stop            Leave a finished turn's message on this repo's
                         doorstep for the owl to collect. Reads the Stop
                         payload on stdin. Never opens a socket.

    owl [<repo>...]      Run the owl in the foreground with a house open for
                         each repo named (default: the one you are in).
                         Collects each house's doorstep when herdr reports a
                         mouse idle, at startup, and on a slow backstop.

    init                 Write Whiska's PreToolUse hook into this repo's own
                         .claude/settings.json, so the rules travel with the
                         repo. Safe to re-run.

    mice                 List what is alive in this repo's house: one line per
                         mouse — branch, mode, what its pane is doing, uptime.

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

  def run(["hook", "stop"], _cwd) do
    stdin() |> Stop.run()
    0
  end

  def run(["owl" | repos], cwd) do
    case start_owl(repos, cwd || File.cwd!()) do
      {:ok, _} ->
        Process.sleep(:infinity)

      {:error, _} ->
        1
    end
  end

  def run(["init"], cwd), do: init(cwd || File.cwd!())

  def run(["mice"], cwd), do: mice(cwd || File.cwd!())

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

  # Runs from the main checkout or any worktree; both name the same house.
  defp mice(cwd) do
    case main_checkout(cwd) do
      {:ok, main} ->
        case Whiska.Mice.list(main) do
          {:ok, rows} ->
            say(Whiska.Mice.render(rows))

          {:error, reason} ->
            IO.puts(:stderr, "whiska: could not reach this repo's house (#{inspect(reason)}).")
            1
        end

      :error ->
        IO.puts(
          :stderr,
          "whiska: #{cwd} is not a git checkout, and not inside a worktree of one."
        )

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

  @doc """
  Start the owl with a house open for each repo. Prints what it opened.

  A repo may be named by its main checkout or by any worktree under it; both
  open the same house. Split out from `run/2` so the CLI can be tested without
  the foreground wait.
  """
  @spec start_owl([Path.t()], Path.t()) :: {:ok, pid()} | {:error, term()}
  def start_owl(repos, cwd \\ File.cwd!()) do
    repos = if repos == [], do: [cwd], else: repos

    with {:ok, houses} <- resolve_houses(repos),
         {:ok, owl} <- start_owl_process() do
      Enum.each(houses, &({:ok, _} = Whiska.Owl.open_house(&1)))

      say(
        "Opened #{length(houses)} #{if length(houses) == 1, do: "house", else: "houses"}:\n" <>
          Enum.map_join(houses, "\n", &"  #{Path.basename(&1)}  (#{&1})") <>
          "\n\nCollecting doorsteps. Ctrl-C to shut them all; nothing on disk is touched."
      )

      {:ok, owl}
    end
  end

  @doc "Stop a running owl, shutting every house. For tests and for `whiska stop`, later."
  @spec stop_owl() :: :ok
  def stop_owl do
    case Process.whereis(Whiska.Owl) do
      nil -> :ok
      pid -> Supervisor.stop(pid)
    end
  end

  defp start_owl_process do
    if Herdr.socket_path() == nil do
      IO.puts(
        :stderr,
        "whiska: HERDR_SOCKET_PATH is not set — herdr events will not arrive; " <>
          "collection falls back to the backstop timer alone."
      )
    end

    case Whiska.Owl.start_link() do
      {:ok, pid} ->
        # The owl outlives whoever started it — the CLI's main process only
        # sleeps, and a test process should not take the owl down with it.
        Process.unlink(pid)
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:ok, pid}

      {:error, reason} ->
        IO.puts(:stderr, "whiska: could not start the owl (#{inspect(reason)}).")
        {:error, reason}
    end
  end

  defp resolve_houses(repos) do
    Enum.reduce_while(repos, {:ok, []}, fn repo, {:ok, acc} ->
      case main_checkout(repo) do
        {:ok, main} ->
          {:cont, {:ok, Enum.uniq(acc ++ [main])}}

        :error ->
          IO.puts(
            :stderr,
            "whiska: #{repo} is not a git checkout, and not inside a worktree of one."
          )

          {:halt, {:error, {:not_a_repo, repo}}}
      end
    end)
  end

  defp main_checkout(repo) do
    path = Path.expand(repo)

    cond do
      match?({:ok, _}, Layout.resolve(path)) ->
        {:ok, layout} = Layout.resolve(path)
        {:ok, layout.main_checkout}

      File.exists?(Path.join(path, ".git")) ->
        {:ok, path}

      true ->
        :error
    end
  end

  defp stdin do
    case IO.read(:stdio, :eof) do
      payload when is_binary(payload) -> payload
      _ -> ""
    end
  end

  defp hook do
    stdin()
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
