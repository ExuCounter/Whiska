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
  alias Whiska.Doctor
  alias Whiska.Doctor.Report
  alias Whiska.Herdr
  alias Whiska.Install
  alias Whiska.Layout
  alias Whiska.Marker
  alias Whiska.Questions
  alias Whiska.Schema.Mouse
  alias Whiska.Schema.Question
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

    start [--force]      Record the herdr pane this is run from as the main
                         session for this repo: where the owl delivers
                         questions. Run it in the main checkout, from the
                         pane your main Claude Code session lives in — from
                         inside that session, `! whiska start` does it.
                         Refuses to replace a main session still running
                         Claude unless --force. Does not launch Claude Code
                         itself yet.

    questions [<id>]     What is waiting on you: one line per open or
                         delivered question, then any orphaned ones, then
                         what is still on the doorstep. With an id, that
                         question in full.

    statusline           Print the one segment the project statusline appends:
                         whether the owl has stopped collecting, how many mice
                         are alive here, one open question in detail or a count
                         for more, and which other whiska on this machine has
                         something waiting. Nothing when nothing is waiting.

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

  def run(["questions"], cwd), do: questions(cwd || File.cwd!())

  def run(["statusline"], cwd), do: statusline(cwd || File.cwd!())

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

        Also wrote the project statusline (#{Install.statusline_path()}), which
        runs your global statusline and appends what is waiting on you here, and
        one slash command per whiska command under .claude/skills/.

        Check them into git so the rules travel with the repo (ADR-0016):

          git add .claude/settings.json .claude/hooks .claude/skills
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
  defp questions(cwd) do
    case main_checkout(cwd) do
      {:ok, main} ->
        case Questions.summary(main) do
          {:ok, summary} ->
            say(Questions.render(summary))

          {:error, reason} ->
            fail("whiska: could not open this repo's house (#{inspect(reason)}).")
        end

      :error ->
        fail("whiska: #{cwd} is not a git checkout, and not inside a worktree of one.")
    end
  end

  # Always 0 and never noisy: this runs on every statusline refresh, and a
  # problem here must not break the line it is appended to.
  defp statusline(cwd) do
    with {:ok, main} <- main_checkout(cwd),
         {:ok, summary} <- Whiska.Statusline.summary(main),
         segment when segment != "" <- Whiska.Statusline.render(summary) do
      IO.puts(segment)
    end

    0
  end

  defp show_question(%Question{} = q) do
    say(
      """
      ##{q.id}  #{branch_of(q.mouse_id)}  #{Questions.verb(q.kind)}  (#{Questions.state(q)}, asked #{Calendar.strftime(q.asked_at, "%Y-%m-%d %H:%M")})

      #{String.trim_trailing(q.text)}

      answer: whiska reply #{q.id} "..."
      """
      |> String.trim_trailing()
    )
  end

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

      {:error, :no_socket} ->
        fail("whiska: HERDR_SOCKET_PATH is not set — cannot reach the mouse's pane.")

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

  defp herdr_socket do
    case Herdr.socket_path() do
      nil -> {:error, :no_socket}
      socket -> {:ok, socket}
    end
  end

  defp describe({:herdr, %{"code" => code, "message" => message}}), do: "#{code}: #{message}"
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
