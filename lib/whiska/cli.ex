defmodule Whiska.CLI do
  @moduledoc """
  The `whiska` binary.

  Built with `mix escript.build`. The hooks invoke it fresh per event (ADR-0030):
  `PreToolUse` opens SQLite, makes one decision, and exits; `Stop` writes one
  doorstep entry and exits. `whiska owl` is the other half — the one supervised
  process per machine (ADR-0001), under a user LaunchAgent once `whiska owl
  install` has run (ADR-0040), or in the foreground before that.
  """

  alias Whiska.Hook.PreToolUse
  alias Whiska.Hook.Stop
  alias Whiska.ClaudeMd
  alias Whiska.Doctor
  alias Whiska.Doctor.Report
  alias Whiska.Herdr
  alias Whiska.Install
  alias Whiska.LaunchAgent
  alias Whiska.Layout
  alias Whiska.Marker
  alias Whiska.OpenHouses
  alias Whiska.Questions
  alias Whiska.Schema.Mouse
  alias Whiska.Schema.Question
  alias Whiska.Storage
  alias Whiska.Waiting

  @version Mix.Project.config()[:version]

  @usage """
  Usage: whiska <command>

    hook pre-tool-use    Decide one Claude Code PreToolUse event. Reads the
                         event payload as JSON on stdin; prints a deny decision
                         as JSON on stdout, or nothing at all to allow.

    hook stop            Leave a finished turn's message on this repo's
                         doorstep for the owl to collect. Reads the Stop
                         payload on stdin. Never opens a socket.

    owl [<repo>...]      Run the owl in the foreground. Opens every house it
                         had open last time (~/.whiska/houses) plus the one
                         you are in, if it has a house; any repo named is
                         opened too and remembered. Collects each house's
                         doorstep when herdr reports a mouse idle, at
                         startup, and on a slow backstop. Refuses while
                         the supervised owl is running.

    owl install          Put the owl under launchd: write a user LaunchAgent
                         (com.whiska.owl) that starts it at login and
                         restarts it if it crashes, and load it now. Logs
                         to ~/.whiska/owl.log. Refuses while any owl runs.
    owl uninstall        Unload that LaunchAgent and remove it.
    owl stop             Ask the supervised owl to exit. It stays installed
                         and returns at the next login, or on `owl start`.
    owl start            Start the supervised owl now.

    stop                 Shut this repo's house only (ADR-0003). Not built:
                         it needs the owl's socket. `whiska owl stop` stops
                         the whole owl.

    init                 Write Whiska's PreToolUse hook into this repo's own
                         .claude/settings.json, so the rules travel with the
                         repo. Safe to re-run.

    start [--force]      Record the herdr pane this is run from as the main
                         session for this repo: where the owl delivers
                         questions. Run it in the main checkout, from the
                         pane your main Claude Code session lives in — from
                         inside that session, `! whiska start` does it.
                         Refuses to replace a main session still running
                         Claude unless --force. Does not launch Claude Code
                         itself yet.

    questions [<id>]     What is waiting on you: one line per open or
    questions --full     delivered question, then any orphaned ones, then
                         what is still on the doorstep. With an id, that
                         question in full; with --full, every open one in
                         full, oldest first, so there is no id to type.

    waiting [--json]     What is waiting on you anywhere on this machine: one
                         line per question, across every house the owl has
                         recorded (~/.whiska/houses), oldest first — repo,
                         branch, what the mouse said, how long it has waited,
                         its id and its herdr pane. Uncollected doorstep
                         entries are in it too. Run from anywhere; it is not
                         repo-scoped, and it reads whether or not the owl is
                         up. --json prints the same rows for a script.

    jump [<repo|branch>] Take me to whatever needs me: focus the main session
                         of the house the oldest thing `whiska waiting` lists
                         belongs to. With a repo name, or a branch — whichever
                         house that mouse works in — focus that house's main
                         session instead, waiting or not. It lands on the
                         whiska, never on a mouse's pane: that is the pane the
                         question was delivered into and the one you answer
                         from. Prints where it went, or says nothing needs you.

                         HERDR_SOCKET_PATH is used when it is set, and herdr's
                         default socket (~/.config/herdr/herdr.sock) when it is
                         not — a hotkey runs with no shell environment at all.

                         For a global hotkey, save this as a Raycast script
                         command and bind it:

                           #!/bin/bash
                           # @raycast.schemaVersion 1
                           # @raycast.title Jump to what needs me
                           # @raycast.mode silent
                           open -a kitty && whiska jump

    statusline           Print the one line herdr's tab bar shows: whether the
                         owl is watching or down (always, so a blank line never
                         passes for a working Whiska), and what is waiting on
                         you anywhere on this machine — one thing named by its
                         branch, several as a count. Not repo-scoped; run it
                         from anywhere. `whiska doctor` prints the herdr config
                         entry that draws it.

    statusline --here    Print this repo's own line, which the Claude Code
                         statusline appends: what is waiting in this house —
                         one thing named by its branch, several as a count —
                         and how many mice are alive here. Nothing when the
                         repo is quiet. `whiska init` wires it up.

    reply <id> <text>    Answer a question. The text is typed into that
                         mouse's pane, and the question is marked answered.

    close <id>           Settle a question by hand, with no answer — for one
                         you dealt with some other way.

    mice                 List what is alive in this repo's house: one line per
                         mouse — branch, mode, what its pane is doing, uptime.

    doctor               Is Whiska working for this repo right now? Checks the
                         binary, runtime, herdr, owl, this repo's hooks and
                         shim (by running them), its house, doorstep and mice.
                         Prints a fix for each finding; changes nothing. Exits
                         1 if anything failed.

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

  def run(["owl", "install"], _cwd), do: owl_install()
  def run(["owl", "uninstall"], _cwd), do: owl_uninstall()
  def run(["owl", "stop"], _cwd), do: owl_stop()
  def run(["owl", "start"], _cwd), do: owl_start()

  def run(["stop"], _cwd) do
    fail("""
    whiska: `whiska stop` shuts one house — this repo's — and leaves the owl
    running for every other (ADR-0003). That needs the owl's socket, which is
    not built yet. To stop the whole owl: whiska owl stop.
    """)
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

  def run(["start" | flags], cwd) when flags in [[], ["--force"]],
    do: start(cwd || File.cwd!(), flags == ["--force"])

  def run(["questions"], cwd), do: questions(cwd || File.cwd!(), :listing)

  def run(["questions", "--full"], cwd), do: questions(cwd || File.cwd!(), :full)

  def run(["statusline"], _cwd), do: statusline()

  def run(["statusline", "--here"], cwd), do: statusline_here(cwd || File.cwd!())

  def run(["waiting"], _cwd), do: waiting(:text)
  def run(["waiting", "--json"], _cwd), do: waiting(:json)

  def run(["jump"], _cwd), do: jump_to_oldest()
  def run(["jump", name], _cwd), do: jump_to_name(name)

  def run(["questions", id], cwd), do: with_question(cwd, id, &show_question/1)

  def run(["reply", id, first | rest], cwd),
    do: with_question(cwd, id, &reply(&1, Enum.join([first | rest], " ")))

  def run(["close", id], cwd), do: with_question(cwd, id, &close/1)

  def run(["mice"], cwd), do: mice(cwd || File.cwd!())

  def run(["doctor"], cwd) do
    cwd = cwd || File.cwd!()

    case main_checkout(cwd) do
      {:ok, main} ->
        report = Doctor.run(main)
        IO.puts(Report.render(report))
        Report.exit_status(report)

      :error ->
        IO.puts(
          :stderr,
          "whiska: #{cwd} is not a git checkout, and not inside a worktree of one."
        )

        1
    end
  end

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
         :ok <- write_statusline(repo_root),
         :ok <- write_skills(repo_root),
         :ok <- write_claude_md(repo_root),
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

        Also wrote the project statusline (#{Install.statusline_path()}). It runs
        your global statusline and appends this repo's own line: what is waiting
        in this house, and how many mice are alive here. It redraws every
        #{Install.statusline_refresh_interval()} seconds, so a mouse that spawns or asks while you
        sit still shows up anyway (ADR-0044). The owl's state and the
        machine-wide view are not on it: they are drawn once on herdr's tab bar
        (ADR-0048), and `whiska doctor` prints the entry that draws them.

        And one slash command per whiska command under .claude/skills/.

        And the worktree protocol went into CLAUDE.md — how a mouse gets spawned,
        the worktree-status marker it ends a turn with, how its question reaches
        you, the shape the message it writes takes, and what it does before it
        says done (ADR-0045). Each part sits in its own named markers, so the
        next init replaces one without touching the others and nothing outside
        them is read at all. Add `keep` to a part's start marker to make it
        yours and Whiska will never rewrite it again.

        Tell the finish part what green means here: a `## Finish` heading in
        CLAUDE.md, outside Whiska's block, naming this repo's checks, where its
        written decisions live and its ticket prefix. Without one a mouse runs
        whatever the tooling obviously offers and says what it assumed.

        Check them into git so the rules travel with the repo (ADR-0016):

          git add .claude/settings.json .claude/hooks .claude/skills CLAUDE.md
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

  defp write_statusline(repo_root) do
    script = Path.join(repo_root, Install.statusline_path())

    with :ok <- File.mkdir_p(Path.dirname(script)),
         :ok <- File.write(script, Install.statusline_script()) do
      File.chmod(script, 0o755)
    end
  end

  defp write_skills(repo_root) do
    Enum.reduce_while(Install.skills(), :ok, fn {rel, body}, :ok ->
      file = Path.join(repo_root, rel)

      with :ok <- File.mkdir_p(Path.dirname(file)),
           :ok <- File.write(file, body) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end

  # The worktree protocol, into the repo's own CLAUDE.md (ADR-0017, ADR-0045).
  # Rewritten on every init — that is the point of the per-part markers, and a
  # part the person has claimed with `keep` is skipped by the merge rather than
  # by refusing to write the file at all.
  defp write_claude_md(repo_root) do
    path = Path.join(repo_root, "CLAUDE.md")

    existing =
      case File.read(path) do
        {:ok, contents} -> contents
        {:error, :enoent} -> ""
      end

    case ClaudeMd.merge(existing) do
      ^existing -> :ok
      merged -> File.write(path, merged)
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

  Which houses (ADR-0039): everything in the open-houses record, plus the
  current checkout's house if it already has one, plus every repo named —
  which are then in the record too. With nothing recorded, nothing named and
  no house here, the house here is opened, as before, so a first run in a
  repo still works. A recorded checkout that is gone is said so and dropped.

  A repo may be named by its main checkout or by any worktree under it; both
  open the same house. Split out from `run/2` so the CLI can be tested without
  the foreground wait.
  """
  @spec start_owl([Path.t()], Path.t()) :: {:ok, pid()} | {:error, term()}
  def start_owl(repos, cwd \\ File.cwd!()) do
    with :ok <- not_supervised(),
         {:ok, named} <- resolve_houses(repos),
         {:ok, houses} <- houses_to_open(named, cwd),
         {:ok, owl} <- start_owl_process() do
      Enum.each(houses, &({:ok, _} = Whiska.Owl.open_house(&1)))

      say(
        case houses do
          [] ->
            "Opened no house. Waiting; nothing on disk is touched."

          _ ->
            "Opened #{length(houses)} #{if length(houses) == 1, do: "house", else: "houses"}:\n" <>
              Enum.map_join(houses, "\n", &"  #{Path.basename(&1)}  (#{&1})") <>
              "\n\nCollecting doorsteps. Ctrl-C to shut them all; nothing on disk is touched."
        end
      )

      {:ok, owl}
    end
  end

  # Two owls would collect the same doorsteps (ADR-0040). The foreground one
  # yields to the supervised one: if launchd has an owl up, this one refuses —
  # unless launchd's owl *is* this process. The wrapper execs, so the job's pid
  # is this BEAM's own pid, and without that test the supervised owl refuses
  # itself, exits 1, and KeepAlive restarts it into a loop (ADR-0040,
  # 2026-09-28 note).
  defp not_supervised do
    case LaunchAgent.status() do
      %{loaded: true, pid: pid} when is_integer(pid) ->
        if pid == os_pid(), do: :ok, else: refuse_to_launchd(pid)

      _ ->
        :ok
    end
  end

  defp os_pid, do: String.to_integer(System.pid())

  defp refuse_to_launchd(pid) do
    IO.puts(
      :stderr,
      "whiska: the owl is already running under launchd (pid #{pid}). " <>
        "Run `whiska owl stop` first if you want it in the foreground."
    )

    {:error, :supervised}
  end

  @doc "Stop a running owl, shutting every house. For tests and for `whiska stop`, later."
  @spec stop_owl() :: :ok
  def stop_owl do
    case Process.whereis(Whiska.Owl) do
      nil -> :ok
      pid -> Supervisor.stop(pid)
    end
  end

  # Under launchd there is no pane's environment to inherit, so a missing
  # HERDR_SOCKET_PATH falls back to herdr's default socket rather than to
  # no herdr at all; the plist carries the variable when it was set at install.
  defp start_owl_process do
    socket =
      case Herdr.socket() do
        {:ok, path} ->
          path

        # The owl starts anyway and picks herdr up when it appears: it is
        # supervised and long-lived, and its houses retry their subscriptions.
        {:error, {:no_socket, default}} ->
          IO.puts(
            :stderr,
            "whiska: HERDR_SOCKET_PATH is not set and there is no socket at herdr's " <>
              "default, #{default} — using it anyway, in case herdr comes up."
          )

          default
      end

    case Whiska.Owl.start_link(herdr_socket: socket) do
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

  # Nothing to open is not an error: launchd starts the owl from the home
  # directory, and before the first `whiska owl <repo>` there is nothing in
  # the record. The owl idles until a house is opened rather than exiting,
  # which under KeepAlive would be a restart loop (ADR-0040).
  defp houses_to_open(named, cwd) do
    case Enum.uniq(recorded_houses() ++ house_here(cwd, named) ++ named) do
      [] ->
        IO.puts(
          :stderr,
          "whiska: no house to open — nothing is recorded in #{OpenHouses.path()} and " <>
            "#{cwd} is not a git checkout. Waiting; run `whiska owl <repo>` to open one."
        )

        {:ok, []}

      houses ->
        {:ok, houses}
    end
  end

  # The record's houses that are still checkouts; the rest are dropped from it.
  defp recorded_houses do
    {kept, gone} = Enum.split_with(OpenHouses.read(), &match?({:ok, _}, main_checkout(&1)))

    Enum.each(gone, fn path ->
      IO.puts(
        :stderr,
        "whiska: #{path} is no longer a git checkout; dropping it from the record."
      )

      OpenHouses.remove(path)
    end)

    kept
  end

  # The current checkout's house when it exists — or, with nothing else to
  # open, the current checkout regardless, which is what a first run needs.
  defp house_here(cwd, named) do
    case main_checkout(cwd) do
      {:ok, main} ->
        cond do
          File.exists?(Storage.database_path(main)) -> [main]
          named == [] and OpenHouses.read() == [] -> [main]
          true -> []
        end

      :error ->
        []
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

      true ->
        case find_main_checkout(path) do
          {:ok, main} -> {:ok, main}
          {:error, _} -> :error
        end
    end
  end

  # -- the main session (ADR-0020) --------------------------------------------

  defp start(cwd, force?) do
    with {:ok, pane} <- current_pane(),
         {:ok, main} <- main_checkout_only(cwd) do
      with_house(main, fn ->
        case Storage.main_pane() do
          ^pane ->
            say("#{pane} is already the main session for #{Path.basename(main)}.")

          nil ->
            record_main(main, pane)

          other ->
            if force? or not running_claude?(other),
              do: record_main(main, pane),
              else: refuse_to_replace(other)
        end
      end)
    else
      {:error, :no_pane} ->
        fail("""
        whiska: not inside a herdr pane (HERDR_PANE_ID is not set).

        The main session is a herdr pane (ADR-0020); run this from the pane your
        main Claude Code session lives in.
        """)

      {:error, :in_worktree} ->
        fail("""
        whiska: this is a worktree, and the main session lives in the main checkout.

        Run `whiska start` from the main checkout's pane instead.
        """)

      {:error, :not_a_repo} ->
        fail("whiska: not inside a git checkout.")
    end
  end

  defp record_main(main, pane) do
    :ok = Storage.set_main_pane(pane)

    say(
      "Recorded #{pane} as the main session for #{Path.basename(main)}. " <>
        "Questions from its mice will be delivered here."
    )
  end

  defp refuse_to_replace(other) do
    fail("""
    whiska: #{other} is already this repo's main session, and is still running Claude.

    Two main sessions would fight over the same questions. If that one is stale,
    or you mean to move the main session here, run `whiska start --force`.
    """)
  end

  defp running_claude?(pane) do
    case Herdr.socket_path() do
      nil ->
        false

      socket ->
        match?({:ok, %{agent: "claude"}}, Herdr.impl().pane(socket, pane))
    end
  end

  defp current_pane do
    case System.get_env("HERDR_PANE_ID") do
      pane when is_binary(pane) and pane != "" -> {:ok, pane}
      _ -> {:error, :no_pane}
    end
  end

  # The main checkout this directory belongs to, refusing a worktree outright.
  defp main_checkout_only(cwd) do
    cond do
      match?({:ok, _}, Layout.resolve(cwd)) -> {:error, :in_worktree}
      true -> find_main_checkout(cwd)
    end
  end

  # Walk up from `cwd` to the nearest directory holding a `.git`.
  defp find_main_checkout(cwd) do
    cwd
    |> Path.expand()
    |> Stream.unfold(fn
      nil -> nil
      "/" -> {"/", nil}
      dir -> {dir, Path.dirname(dir)}
    end)
    |> Enum.find_value({:error, :not_a_repo}, fn dir ->
      if File.exists?(Path.join(dir, ".git")), do: {:ok, dir}
    end)
  end

  # -- questions ----------------------------------------------------------------

  # The listing and the statusline read the same summary (Whiska.Questions),
  # so the two can never disagree about what is waiting. Works from the main
  # checkout or any worktree of the house, like `whiska mice`.
  defp questions(cwd, shape) do
    case main_checkout(cwd) do
      {:ok, main} ->
        case Questions.summary(main) do
          {:ok, summary} ->
            say(render(summary, shape))

          {:error, reason} ->
            fail("whiska: could not open this repo's house (#{inspect(reason)}).")
        end

      :error ->
        fail("whiska: #{cwd} is not a git checkout, and not inside a worktree of one.")
    end
  end

  defp render(summary, :listing), do: Questions.render(summary)
  defp render(summary, :full), do: Questions.render_full(summary)

  # Not repo-scoped: the line is machine-wide and herdr draws one of them for
  # the whole session (ADR-0048). Always 0 and never noisy — this runs every
  # few seconds, and herdr clears the entry on a non-zero exit.
  defp statusline do
    IO.puts(Whiska.Statusline.render(Whiska.Statusline.summary()))
    0
  end

  # Repo-scoped, and works from a worktree of the house the way `whiska mice`
  # does. Always 0 and never noisy: this runs on a timer in every session, and
  # a directory with no house simply has nothing to say.
  defp statusline_here(cwd) do
    line =
      case main_checkout(cwd) do
        {:ok, main} -> Whiska.Statusline.render_house(Whiska.Statusline.house(main))
        :error -> ""
      end

    IO.puts(line)
    0
  end

  # -- waiting and jump (ADR-0043) ---------------------------------------------

  # Not repo-scoped, unlike everything above it: the record says which repos to
  # look in (ADR-0039), and the answer is the same from anywhere on the machine.
  defp waiting(:json), do: say(Waiting.json(Waiting.list()))
  defp waiting(:text), do: say(Waiting.render(Waiting.list()))

  # A jump lands on a house's main session, never on a mouse's pane (ADR-0043):
  # that is the pane the question was delivered into, and the pane the person
  # answers from. The mouse's pane is the mouse's workplace.
  #
  # Nothing waiting is a normal answer, not a failure — the hotkey is pressed
  # on spec, and exiting 1 would make a Raycast script look broken. So is a
  # house with no main session recorded: something to run `whiska start` in,
  # not something that failed.
  defp jump_to_oldest do
    case Waiting.list() do
      [] -> say("🦉 Nothing needs you · the owl delivers when something does")
      [oldest | _] -> jump_to_house(oldest.main_checkout)
    end
  end

  defp jump_to_name(name) do
    case Waiting.house_for(name) do
      {:ok, main} ->
        jump_to_house(main)

      {:error, :no_such_target} ->
        fail(
          "whiska: no recorded house is called #{name}, and none has a live mouse on " <>
            "a branch of that name. `whiska waiting` lists what is waiting anywhere."
        )
    end
  end

  defp jump_to_house(main) do
    repo = Path.basename(main)

    case Waiting.main_session(main) do
      nil ->
        say(
          "whiska: #{repo} has no main session recorded, so there is nowhere to jump to. " <>
            "Run `whiska start` in its main pane."
        )

      pane ->
        focus(pane, repo)
    end
  end

  defp focus(pane, where) do
    case herdr_socket() do
      {:ok, socket} ->
        case Herdr.impl().focus(socket, pane) do
          :ok ->
            say("Jumped to #{where}'s main session — pane #{pane}.")

          {:error, reason} ->
            fail("whiska: could not focus #{pane} (#{describe(reason)}). Nothing moved.")
        end

      {:error, {:no_socket, default}} ->
        no_socket(default, "ask to focus a pane")
    end
  end

  # The shape lives in Whiska.Questions, so one question read by id and one
  # block of `whiska questions --full` cannot drift apart. This question was
  # loaded by id, without its mouse, so the branch is looked up here.
  defp show_question(%Question{} = q), do: say(Questions.full(q, branch_of(q.mouse_id)))

  # Orphaned means the mouse died (ADR-0026) or its worktree went (ADR-0036);
  # the person needs to know which, and where the work is.
  defp reply(%Question{status: "orphaned"} = q, _text) do
    case Storage.mouse(q.mouse_id) do
      %Mouse{} = mouse -> dead_mouse(q, mouse)
      nil -> fail("whiska: ##{q.id} is orphaned and its mouse is unknown.")
    end
  end

  defp reply(%Question{status: status} = q, _text) when status not in ["open", "sent"] do
    fail("whiska: ##{q.id} is already #{status}; there is nothing to answer.")
  end

  defp reply(%Question{} = q, text) do
    with {:ok, mouse} <- live_mouse(q),
         {:ok, socket} <- herdr_socket(),
         :ok <- Herdr.impl().prompt(socket, mouse.pane, text),
         {:ok, _} <- Storage.answer(q.id, text) do
      say("Answered ##{q.id} (#{mouse.branch}): typed into #{mouse.pane}.")
    else
      {:error, {:dead, mouse}} ->
        dead_mouse(q, mouse)

      {:error, {:no_socket, default}} ->
        no_socket(default, "reach the mouse's pane through")

      {:error, reason} ->
        fail(
          "whiska: could not type the answer into the mouse's pane (#{describe(reason)}). " <>
            "##{q.id} is unchanged."
        )
    end
  end

  defp dead_mouse(q, mouse) do
    fail("""
    whiska: ##{q.id}'s mouse (#{mouse.branch}) is dead — its pane is gone.

    The worktree is still on disk at #{mouse.path}. `whiska reopen` is not
    built yet; start Claude Code there by hand and pass the answer on
    yourself, then `whiska close #{q.id}`.
    """)
  end

  defp close(%Question{} = q) do
    case Storage.close_question(q.id) do
      {:ok, _} -> say("Closed ##{q.id} without an answer.")
      {:error, :not_answerable} -> fail("whiska: ##{q.id} is already #{q.status}.")
      {:error, reason} -> fail("whiska: could not close ##{q.id} (#{inspect(reason)}).")
    end
  end

  defp live_mouse(%Question{mouse_id: mouse_id}) do
    case Storage.mouse(mouse_id) do
      %Mouse{died_at: nil, pane: pane} = mouse when is_binary(pane) -> {:ok, mouse}
      %Mouse{} = mouse -> {:error, {:dead, mouse}}
      nil -> {:error, :no_such_mouse}
    end
  end

  # One fallback for every command that talks to herdr, the owl's included
  # (ADR-0040): `HERDR_SOCKET_PATH` when a herdr pane's shell set it, herdr's
  # fixed default otherwise. `whiska jump` is typically run by a hotkey with no
  # shell environment at all, which is the same position launchd's owl is in.
  defp herdr_socket, do: Herdr.socket()

  defp no_socket(default, cannot) do
    fail(
      "whiska: HERDR_SOCKET_PATH is not set and there is no socket at herdr's default, " <>
        "#{default} — so there is no herdr to #{cannot}. Is herdr running?"
    )
  end

  defp describe({:herdr, %{"code" => code, "message" => message}}), do: "#{code}: #{message}"
  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason)

  defp branch_of(mouse_id) do
    case Storage.mouse(mouse_id) do
      %Mouse{branch: branch} when is_binary(branch) -> branch
      _ -> mouse_id
    end
  end

  # Run `work` on one question of this house, by id.
  defp with_question(cwd, id, work) do
    case Integer.parse(id) do
      {n, ""} ->
        with_house(cwd, fn ->
          case Storage.question(n) do
            nil -> fail("whiska: there is no question ##{id} in this house.")
            question -> work.(question)
          end
        end)

      _ ->
        fail(
          "whiska: #{id} is not a question id — expected a number, as `whiska questions` shows."
        )
    end
  end

  # Open the house this directory belongs to — main checkout or a worktree of
  # it — run `work`, and close it again.
  defp with_house(cwd, work) do
    cwd = cwd || File.cwd!()

    case main_checkout(cwd) do
      {:ok, main} ->
        case Storage.open(main) do
          {:ok, handle} ->
            try do
              work.()
            after
              Storage.close(handle)
            end

          {:error, reason} ->
            fail("whiska: could not open this repo's house (#{inspect(reason)}).")
        end

      :error ->
        fail("whiska: #{cwd} is not a git checkout, and not inside a worktree of one.")
    end
  end

  # -- the owl under launchd (ADR-0040) ------------------------------------------

  defp owl_install do
    paths = LaunchAgent.paths()
    uid = LaunchAgent.uid()
    run = LaunchAgent.runner()
    status = LaunchAgent.status(uid, run)
    env = Application.get_env(:whiska, :env) || System.get_env()

    with :ok <- no_other_owl(status),
         :ok <- Install.write_herdr_status(),
         :ok <- LaunchAgent.install(paths, env),
         :ok <- if(status.loaded, do: LaunchAgent.bootout(uid, run), else: :ok),
         :ok <- LaunchAgent.bootstrap(paths, uid, run) do
      if env["HERDR_SOCKET_PATH"] in [nil, ""] do
        IO.puts(
          :stderr,
          "whiska: HERDR_SOCKET_PATH is not set here, so the plist does not carry it; " <>
            "the owl will use herdr's default, #{Herdr.default_socket_path(env)}. " <>
            "Run this from a herdr pane to pin it."
        )
      end

      say("""
      Installed #{LaunchAgent.label()} and started the owl under launchd.

        job:     #{paths.plist}
        runs:    #{paths.wrapper}  (whiska owl, no arguments — reopens the recorded houses)
        log:     #{paths.log}

      launchd starts it at login and restarts it if it crashes. `whiska owl stop`
      turns it off until the next login or `whiska owl start`; `whiska owl
      uninstall` removes it. `whiska doctor` shows its state.

      Also wrote #{Install.herdr_status_path()}, the script herdr's tab bar runs
      to draw the owl's line (ADR-0048). Nothing wires it for you — herdr's
      config is yours. Paste this into #{Whiska.Herdr.config_path()} and commit
      it with your dotfiles:

      #{Install.tab_bar_right_snippet()}
      Then `herdr server reload-config`. `whiska doctor` says whether it took.
      """)
    else
      {:error, :owl_running} -> 1
      {:error, reason} -> fail("whiska: could not install the LaunchAgent (#{describe(reason)}).")
    end
  end

  # Two owls collecting the same doorsteps is the one state install must
  # never produce, so it refuses while any owl is in the process table — the
  # supervised one included, since reinstalling means stopping it first.
  defp no_other_owl(status) do
    case owl_pids() do
      [] ->
        :ok

      pids ->
        if status.pid in pids,
          do:
            fail("""
            whiska: the owl is already running under launchd (pid #{status.pid}).
            To reinstall, `whiska owl stop` first, then `whiska owl install`.
            """),
          else:
            fail("""
            whiska: an owl is already running in the foreground (pid #{Enum.join(pids, ", ")}).
            Two owls would collect the same doorsteps. The handover is:

              1. Ctrl-C the foreground owl in its pane.
              2. `whiska owl install` again — launchd's owl reopens the same houses.
            """)

        {:error, :owl_running}
    end
  end

  defp owl_uninstall do
    paths = LaunchAgent.paths()
    uid = LaunchAgent.uid()
    run = LaunchAgent.runner()
    status = LaunchAgent.status(uid, run)

    with :ok <- if(status.loaded, do: LaunchAgent.bootout(uid, run), else: :ok),
         :ok <- LaunchAgent.uninstall(paths) do
      say(
        "Removed #{LaunchAgent.label()}: the owl is no longer supervised. " <>
          "The log at #{paths.log} and the open-houses record are kept. " <>
          "`whiska owl install` puts it back."
      )
    else
      {:error, :not_installed} ->
        say("#{LaunchAgent.label()} is not installed; nothing to remove.")

      {:error, reason} ->
        fail("whiska: could not remove the LaunchAgent (#{describe(reason)}).")
    end
  end

  defp owl_stop do
    uid = LaunchAgent.uid()
    run = LaunchAgent.runner()

    case LaunchAgent.status(uid, run) do
      %{loaded: false} ->
        fail(
          case owl_pids() do
            [] ->
              "whiska: #{LaunchAgent.label()} is not installed, and no owl is running."

            pids ->
              "whiska: #{LaunchAgent.label()} is not installed; the owl running (pid " <>
                "#{Enum.join(pids, ", ")}) is in the foreground — Ctrl-C it in its pane."
          end
        )

      %{pid: nil} ->
        say(
          "The owl is not running under launchd; nothing to stop. `whiska owl start` starts it."
        )

      %{pid: pid} ->
        case LaunchAgent.stop(uid, run) do
          :ok ->
            say(
              "Asked the owl (pid #{pid}) to exit. It stays installed: launchd starts it " <>
                "again at the next login, or now with `whiska owl start`."
            )

          {:error, reason} ->
            fail("whiska: could not stop the owl (#{reason}).")
        end
    end
  end

  defp owl_start do
    uid = LaunchAgent.uid()
    run = LaunchAgent.runner()

    case LaunchAgent.status(uid, run) do
      %{loaded: false} ->
        fail(
          "whiska: #{LaunchAgent.label()} is not installed. `whiska owl install` installs and starts it."
        )

      %{pid: pid} when is_integer(pid) ->
        say("The owl is already running under launchd (pid #{pid}).")

      _ ->
        case LaunchAgent.start(uid, run) do
          :ok -> say("Started the owl under launchd (#{LaunchAgent.label()}).")
          {:error, reason} -> fail("whiska: could not start the owl (#{reason}).")
        end
    end
  end

  defp owl_pids, do: (Application.get_env(:whiska, :owl_pids) || (&Whiska.Owl.pids/0)).()

  defp fail(message) do
    IO.puts(:stderr, String.trim_trailing(message))
    1
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
