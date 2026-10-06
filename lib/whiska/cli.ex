defmodule Whiska.CLI do
  @moduledoc """
  The `whiska` binary.

  Built with `mix escript.build`. The hooks invoke it fresh per event (ADR-0030):
  `PreToolUse` opens SQLite, makes one decision, and exits; `Stop` writes one
  doorstep entry and exits. `whiska owl` is the other half — the one supervised
  process per machine (ADR-0001), under the platform's service manager —
  launchd on macOS, systemd on Linux — once `whiska owl install` has run
  (ADR-0040), or in the foreground before that.
  """

  alias Whiska.Hook.PreToolUse
  alias Whiska.Hook.Stop
  alias Whiska.ClaudeMd
  alias Whiska.Delivery.Mode
  alias Whiska.Doctor
  alias Whiska.Doctor.Report
  alias Whiska.Herdr
  alias Whiska.Install
  alias Whiska.Layout
  alias Whiska.Marker
  alias Whiska.OpenHouses
  alias Whiska.Questions
  alias Whiska.Schema.Mouse
  alias Whiska.Schema.Question
  alias Whiska.ServiceManager
  alias Whiska.Storage
  alias Whiska.Waiting

  @version Mix.Project.config()[:version]

  # The catch-all comes from `priv/models.json`, through `Whiska.Shape`, so the
  # help never names a model itself.
  @catch_all Whiska.Shape.catch_all()
             |> then(fn %{model: model, effort: effort} ->
               "#{model || "your own default model"}, #{effort || "your own default"} effort"
             end)

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

    owl install          Put the owl under this machine's service manager:
                         a user LaunchAgent (com.whiska.owl) on macOS, a
                         systemd user unit (whiska-owl.service) on Linux.
                         It starts the owl at login and restarts it if it
                         crashes, and starts it now. Logs to
                         ~/.whiska/owl.log. Refuses while any owl runs.
    owl uninstall        Unload that job and remove it.
    owl stop             Ask the supervised owl to exit. It stays installed
                         and returns on `owl start`, or when the service
                         manager next starts your user session.
    owl start            Start the supervised owl now.

    stop                 Shut this repo's house only (ADR-0003). Not built:
                         it needs the owl's socket. `whiska owl stop` stops
                         the whole owl.

    init                 Write Whiska's hooks, statusline, skills and CLAUDE.md
                         block into this repo's own .claude/, so the rules
                         travel with the repo. Safe to re-run.

    init --global        The same, into ~/.claude, for every repo on this
                         machine — for a repo that cannot carry a committed
                         .claude/ of its own. A repo that has run `whiska init`
                         still wins there; this copy stands down. Safe to
                         re-run, and it writes through a symlink rather than
                         replacing it, so a dotfiles repo stays connected.

    uninstall            Take Whiska back out of this repo: the block, the
    uninstall --global   hooks, the scripts and the skills. The house — its
                         mice, its questions, its doorstep — is untouched, and
                         so is a part you claimed with `keep`. With --global,
                         the same against ~/.claude.

    start [--force]      Record the herdr pane this is run from as the main
         [--no-claude]   session for this repo: where the owl delivers
                         questions. Run it in the main checkout, in the pane
                         you want your main Claude Code session in — and if
                         nothing is running there, it starts Claude Code for
                         you. From inside a session already running,
                         `! whiska start` records the pane and starts nothing.
                         Refuses to replace a main session still running
                         Claude unless --force. --no-claude records the pane
                         and leaves starting Claude to you.

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

                         For a global hotkey on macOS, save this as a Raycast
                         script command and bind it:

                           #!/bin/bash
                           # @raycast.schemaVersion 1
                           # @raycast.title Jump to what needs me
                           # @raycast.mode silent
                           open -a kitty && whiska jump

                         On Linux, bind `whiska jump` to a key in your
                         desktop's keyboard shortcut settings.

    One word each, for handling questions. `whiska init --global` installs
    them as plain commands under ~/.whiska/bin, and as slash commands in the
    main session. The long names above keep working.

    inbox [--json]       What is waiting on you anywhere, oldest first — the
                         rows `waiting` prints, with why each is not being
                         delivered (held, away, focus: <branch>) and a first
                         line when you are away.
    show [<id>]          This repo's open questions in full, or one by id.
    reply <id> <text>    Answer it; no quotes needed around the text.
    dismiss <id>         Close it without answering (`close`).
    away                 Nothing is delivered to any main session on this
                         machine until `resume`. Mice keep working; `inbox`
                         keeps listing. One setting for the whole machine.
    focus [<branch>]     Only that mouse's questions reach this repo's main
                         session; the rest wait, still listed by `inbox`. A
                         question already delivered from another mouse no
                         longer blocks the focused one. Per repo. With no
                         branch, print the focus.
    hold <branch>        That mouse stops at its next tool call, its questions
                         sit in the inbox undelivered, and it is never offered
                         for landing. `resume <branch>` lifts it.
    resume [<branch>]    End away and this repo's focus — outside any repo,
                         every repo's focus; what waited arrives oldest first.
                         With a branch, lift that mouse's hold and, when it
                         stopped because of the hold, tell it to carry on.

    statusline           Print the one line herdr's tab bar shows: whether the
                         owl is watching or down (always, so a blank line never
                         passes for a working Whiska), and what is waiting on
                         you anywhere on this machine — one thing named by its
                         branch, several as a count. Not repo-scoped; run it
                         from anywhere. `whiska doctor` prints the herdr config
                         entry that draws it.

    statusline --here    Print this repo's board, the same one the Claude Code
                         statusline draws, worked out now rather than read from
                         the file the owl keeps. Nothing when the repo is
                         quiet. `whiska init` wires it up.

    reply <id> <text>    Answer a question. The text is typed into that
                         mouse's pane, and the question is marked answered.

    close <id>           Settle a question by hand, with no answer — for one
                         you dealt with some other way.

    mice                 List what is alive in this repo's house: one line per
                         mouse — branch, mode, what its pane is doing, uptime.

    watch                Print this repo's board once: a row per mouse — its
                         branch, what its pane is doing, and the question
                         waiting on you, else what it is working on, else what
                         it is stuck in. The owl
                         writes this every second for the
                         statusline to print; run it yourself when that looks
                         wrong.

    doctor               Is Whiska working for this repo right now? Checks the
                         binary, runtime, herdr, owl, this repo's hooks and
                         shim (by running them), its house, doorstep and mice.
                         Prints a fix for each finding; changes nothing. Exits
                         1 if anything failed.

    worktrees            List this repo's linked worktrees as tab-separated
                         lines: branch, path, herdr workspace id, the id of the
                         pane in it, and what that pane is doing. A dash where
                         there is no workspace open. The worktree skills read
                         herdr through this, so they need no jq.

    mode                 Print this mouse's mode.
    mode build|sniff     Set it. A build mouse makes changes, confined to its
                         own worktree. A sniff mouse investigates and reports,
                         and may not write anything at all. Its model and
                         effort stay what it was started on; moved off the
                         mode it was shaped as, it says so, and so does
                         `whiska mice`. Like shape, makes git ignore the
                         worktree's .whiska-spec.md.

    shape build|sniff [--model <name>] [--effort <level>]
                         Give a fresh mouse its shape, before Claude starts
                         (ADR-0069): record its mode, model and effort, and
                         print the flags to start Claude with, or nothing.
                         Also makes git ignore the worktree's .whiska-spec.md.
                         Fails rather than guess, so a spawn stops before
                         Claude. A model or effort left out is the last rule's
                         in priv/models.json: #{@catch_all}.
    shape --rules        Print priv/models.json as this build carries it: the
                         modes, and the ordered rules a spawn chooses a model
                         and an effort by.

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

  def run(["init"], cwd), do: init(:repo, cwd || File.cwd!())

  def run(["init", "--global"], _cwd), do: init(:global, Install.root(:global))

  def run(["uninstall"], cwd), do: uninstall(:repo, cwd || File.cwd!())

  def run(["uninstall", "--global"], _cwd), do: uninstall(:global, Install.root(:global))

  def run(["start" | flags], cwd) do
    case Enum.split_with(flags, &(&1 in ["--force", "--no-claude"])) do
      {known, []} ->
        start(cwd || File.cwd!(), "--force" in known, "--no-claude" not in known)

      {_known, [unknown | _]} ->
        fail("whiska: `start` takes --force and --no-claude, not #{unknown}.")
    end
  end

  def run(["questions"], cwd), do: questions(cwd || File.cwd!(), :listing)

  def run(["questions", "--full"], cwd), do: questions(cwd || File.cwd!(), :full)

  def run(["statusline"], _cwd), do: statusline()

  def run(["statusline", "--here"], cwd), do: statusline_here(cwd || File.cwd!())

  def run(["waiting"], _cwd), do: waiting(:text)
  def run(["waiting", "--json"], _cwd), do: waiting(:json)

  def run(["jump"], _cwd), do: jump_to_oldest()
  def run(["jump", name], _cwd), do: jump_to_name(name)

  def run(["inbox"], _cwd), do: inbox(:text)
  def run(["inbox", "--json"], _cwd), do: inbox(:json)
  def run(["show"], cwd), do: questions(cwd || File.cwd!(), :full)
  def run(["show", id], cwd), do: with_question(cwd, id, &show_question/1)
  def run(["dismiss", id], cwd), do: with_question(cwd, id, &close/1)
  def run(["away"], _cwd), do: away()
  def run(["focus"], cwd), do: with_house(cwd, &show_focus/0)
  def run(["focus", branch], cwd), do: with_house(cwd, fn -> set_focus(branch) end)
  def run(["hold", branch], cwd), do: with_house(cwd, fn -> hold(branch) end)
  def run(["resume"], cwd), do: resume(cwd || File.cwd!())
  def run(["resume", branch], cwd), do: with_house(cwd, fn -> resume_branch(branch) end)

  def run(["questions", id], cwd), do: with_question(cwd, id, &show_question/1)

  def run(["reply", id, first | rest], cwd),
    do: with_question(cwd, id, &reply(&1, Enum.join([first | rest], " ")))

  def run(["close", id], cwd), do: with_question(cwd, id, &close/1)

  def run(["mice"], cwd), do: mice(cwd || File.cwd!())

  def run(["watch"], cwd), do: watch(cwd || File.cwd!())

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

  def run(["worktrees"], cwd), do: worktrees(cwd || File.cwd!())

  def run(["mode"], cwd), do: with_mouse(cwd, &show_mode/2)

  def run(["mode", mode], cwd) when mode in ["build", "sniff"],
    do: with_mouse(cwd, &set_mode(&1, &2, mode))

  def run(["mode", other], _cwd) do
    IO.puts(:stderr, "whiska: #{other} is not a mode — expected build or sniff.")
    1
  end

  def run(["shape", "--rules"], _cwd) do
    IO.write(Whiska.Shape.rules())
    0
  end

  # The arguments are read before the house is opened, so a mistyped model
  # leaves no mouse behind with a shape nobody asked for.
  def run(["shape" | args], cwd) do
    case Whiska.Shape.parse(args) do
      {:ok, shape} ->
        with_mouse(cwd, &shape(&1, &2, shape))

      {:error, message} ->
        IO.puts(:stderr, "whiska: #{message}")
        1
    end
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

  defp init(scope, root) do
    path = Path.join(root, ".claude/settings.json")
    shim = Path.join(root, Install.shim_path())

    with {:ok, settings} <- read_settings(path),
         merged = Install.merge(settings, scope),
         :ok <- record_displaced(scope, root, settings),
         :ok <- File.mkdir_p(Path.dirname(shim)),
         :ok <- write_unchanged(shim, Install.shim(scope)),
         :ok <- make_executable(shim),
         :ok <- write_statusline(root),
         :ok <- write_skills(scope, root),
         retired = remove_retired_skills(root),
         {:ok, commands} <- write_commands(scope),
         :ok <- write_claude_md(scope, root),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- write_unchanged(path, JSON.encode!(merged) |> reformat()) do
      say(told(scope) <> retired_note(retired) <> commands_note(commands))
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

  # A skill an older Whiska wrote and this one no longer ships goes, where it
  # is a plain file of Whiska's; one reached through a symlink is the person's
  # (ADR-0056) and stays. Returns the names removed.
  defp remove_retired_skills(root) do
    for rel <- Install.retired_skills(),
        file = Path.join(root, rel),
        File.regular?(file),
        not through_link?(root, rel) do
      File.rm(file)
      File.rmdir(Path.dirname(file))
      rel |> Path.dirname() |> Path.basename()
    end
  end

  defp retired_note([]), do: ""

  defp retired_note(names) do
    "\n\nRemoved #{Enum.join(names, " and ")}: the one-word skills replace them " <>
      "(/show, /reply and the rest)."
  end

  # The one-word commands are the machine's, like the home they are written
  # under; the per-repo install writes none.
  defp write_commands(:repo), do: {:ok, nil}
  defp write_commands(:global), do: Install.write_commands()

  defp commands_note(nil), do: ""

  defp commands_note({written, skipped}) do
    dir = Install.commands_dir()

    """


    The one-word commands went to #{dir}:

      #{Enum.join(written, " ")}

    Put it on PATH once, ahead of the rest, so each word runs as itself:

      export PATH="#{dir}:$PATH"
    """
    |> String.trim_trailing()
    |> Kernel.<>(skipped_note(skipped))
  end

  defp skipped_note([]), do: ""

  defp skipped_note(skipped) do
    """


    Skipped, because another program on your PATH already answers to the word;
    the long `whiska` name still works for each:

    #{Enum.map_join(skipped, "\n", fn {word, other} -> "  #{word} → #{other}" end)}
    """
    |> String.trim_trailing()
  end

  # The global statusLine Whiska is about to take over, kept where both scripts
  # read it back and run it first (ADR-0056). Only the global install displaces
  # anything: a project line is Claude Code's own replacement of the global one,
  # and the repo's script already runs that one.
  defp record_displaced(:repo, _root, _settings), do: :ok

  defp record_displaced(:global, root, settings) do
    case Install.displaced(settings) do
      nil ->
        :ok

      command ->
        path = Path.join(root, Install.base_statusline_path())

        with :ok <- File.mkdir_p(Path.dirname(path)), do: File.write(path, command)
    end
  end

  defp told(:repo) do
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
    says done — that last part is a pointer at the `whiska-finish` skill,
    installed with the rest, so the five steps cost nothing until a turn is
    actually ending (ADR-0045, ADR-0055). Each part sits in its own named markers, so the
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
    |> then(&(&1 <> global_note()))
  end

  defp told(:global) do
    """
    Wrote Whiska into ~/.claude, for every repo on this machine.

    #{written()}

    #{landed()}

    Nothing else is needed per repo. The hooks work out for themselves which
    worktree they are firing in, and the board is found by the directory the
    session is sitting in — so a repo that cannot carry a committed `.claude/`
    is covered by this and by its house alone.

    Your own global statusline still runs first; it was kept at
    ~/#{Install.base_statusline_path()} and the board goes under it.

    Per repo there is still one thing worth writing: a `## Finish` heading in
    that repo's own CLAUDE.md naming its checks, where its written decisions
    live and its ticket prefix. Without one a mouse runs whatever the tooling
    obviously offers and says what it assumed.

    A repo that has run `whiska init` keeps winning — its own hooks, block and
    skills are the ones in force, and this copy stands down there. To hand a
    repo over to this one instead, run `whiska uninstall` inside it and commit
    what that removes.
    """
    |> String.trim()
    |> then(&(&1 <> through_links()))
  end

  defp written do
    [
      {"~/.claude/CLAUDE.md", "the worktree protocol"},
      {"~/" <> Install.shim_path(), "the hook shim both hooks call"},
      {"~/" <> Install.statusline_path(), "the board"},
      {"~/.claude/settings.json", "PreToolUse, Stop and the statusLine"},
      {"~/.claude/skills/", "inbox, show, reply, dismiss, focus, away, hold, resume,"},
      {"", "whiska-delivered, whiska-finish, whiska-spec, grilling,"},
      {"", "spawn-worktree, send-to-worktree, drop-worktree"}
    ]
    |> Enum.map_join("\n", fn {path, what} ->
      "  " <> String.pad_trailing(path, 40) <> what
    end)
  end

  # A dotfiles repo may still install the worktree skills, each as a link into
  # it. The write goes through the link (ADR-0056), so where each of the three
  # really landed is printed, plain file or not. "Through a symlink" is the
  # same test uninstall uses, so a linked `~/.claude/skills` counts too.
  defp landed do
    home = Install.root(:global)

    rows =
      for rel <- Install.worktree_skill_paths() do
        path = Path.join(home, rel)

        {rel |> Path.dirname() |> Path.basename(), Layout.canonical(path),
         through_link?(home, rel)}
      end

    table =
      Enum.map_join(rows, "\n", fn {name, real, linked?} ->
        "  " <>
          String.pad_trailing(name, 18) <>
          real <> if(linked?, do: "  (through a symlink)", else: "")
      end)

    "The worktree skills landed here:\n\n" <> table <> linked_skills_note(rows)
  end

  defp linked_skills_note(rows) do
    if Enum.any?(rows, &elem(&1, 2)) do
      """


      One through a symlink changed a file in the repo the link points into. Once
      that repo stops installing it, delete the link and run this again for a
      plain file.
      """
      |> String.trim_trailing()
    else
      ""
    end
  end

  # ~/.claude/CLAUDE.md and ~/.claude/settings.json are commonly links into a
  # dotfiles repo. Every write went through the link, so the change is sitting
  # in that repo and the person's next move is there, not here.
  defp through_links do
    # The worktree skills have their own lines above, link or not.
    case Enum.reject(Install.global_links(), &(elem(&1, 0) in Install.worktree_skill_paths())) do
      [] ->
        ""

      links ->
        """


        Some of those paths are symlinks, so the change landed where they point:

        #{Enum.map_join(links, "\n", fn {rel, target} -> "  ~/#{rel} → #{target}" end)}

        The links themselves are untouched. Commit the change in the repo that
        owns them.
        """
        |> String.trim_trailing()
    end
  end

  # Said only where it changes what the person does next: a repo they are about
  # to commit Whiska's files into, on a machine that already covers every repo.
  defp global_note do
    if Install.global_installed?() do
      """


      Whiska is also installed globally in ~/.claude. This repo's own copy is the
      one in force here, and the global one stands down. If you would rather this
      repo relied on the global install, run `whiska uninstall` here instead.
      """
      |> String.trim_trailing()
    else
      ""
    end
  end

  defp uninstall(scope, root) do
    path = Path.join(root, ".claude/settings.json")
    base = read_base_statusline(scope, root)

    with {:ok, settings} <- read_settings(path),
         :ok <- rewrite_settings(path, Install.unmerge(settings, base)) do
      {removed, linked} = remove_files(scope, root)
      commands = remove_commands(scope)
      say(removal_report(scope, removed ++ remove_claude_md(scope, root) ++ commands, linked))
    else
      {:error, :unparseable} ->
        IO.puts(:stderr, "whiska: could not parse #{path} — leaving it alone.")
        1

      {:error, reason} ->
        IO.puts(:stderr, "whiska: could not write #{path} (#{inspect(reason)}).")
        1
    end
  end

  defp remove_commands(:repo), do: []

  defp remove_commands(:global),
    do: Enum.map(Install.remove_commands(), &Path.join(Install.commands_dir(), &1))

  defp read_base_statusline(:repo, _root), do: nil

  defp read_base_statusline(:global, root) do
    case File.read(Path.join(root, Install.base_statusline_path())) do
      {:ok, command} -> String.trim(command)
      {:error, _} -> nil
    end
  end

  # A settings file that was never there is not created just to be emptied.
  defp rewrite_settings(path, settings) do
    if File.exists?(path),
      do: File.write(path, JSON.encode!(settings) |> reformat()),
      else: :ok
  end

  # A path that resolves outside the root is somebody else's file seen through a
  # link — a dotfiles repo, most often. Deleting it would quietly take something
  # out of that repo, so it is named and left exactly where it is. The whole path
  # is resolved, not only its last segment: `~/.claude/skills` is commonly one
  # link rather than a link per skill file.
  defp remove_files(scope, root) do
    paths =
      [Install.shim_path(), Install.statusline_path()] ++
        Enum.map(Install.skills(scope), &elem(&1, 0)) ++ base_statusline(scope)

    paths
    |> Enum.filter(&File.exists?(Path.join(root, &1)))
    |> Enum.split_with(&ours_to_remove?(root, &1))
    |> then(fn {removable, linked} ->
      for rel <- removable do
        File.rm(Path.join(root, rel))
        File.rmdir(Path.dirname(Path.join(root, rel)))
      end

      {removable, linked}
    end)
  end

  defp ours_to_remove?(root, rel), do: not through_link?(root, rel)

  # Any segment below the root being a link counts, wherever it points: a
  # dotfiles repo usually sits inside the home it is linked from.
  defp through_link?(root, rel) do
    Layout.canonical(Path.join(root, rel)) != Path.join(Layout.canonical(root), rel)
  end

  defp base_statusline(:global), do: [Install.base_statusline_path()]
  defp base_statusline(:repo), do: []

  defp remove_claude_md(scope, root) do
    path = claude_md_path(scope, root)

    with {:ok, contents} <- File.read(path),
         stripped when stripped != contents <- ClaudeMd.remove(contents),
         :ok <- File.write(path, stripped) do
      [Path.relative_to(path, root)]
    else
      _ -> []
    end
  end

  defp removal_report(scope, [], linked) do
    String.trim("Nothing of Whiska's to remove #{where(scope)}." <> left_linked(linked))
  end

  defp removal_report(scope, removed, linked) do
    """
    Removed Whiska #{where(scope)}:

    #{Enum.map_join(removed, "\n", &("  " <> &1))}

    The house is untouched: its mice, its questions and what is on its doorstep
    are all still there, and `whiska init` puts the rest back.#{left_linked(linked)}
    """
    |> String.trim()
  end

  defp left_linked([]), do: ""

  defp left_linked(linked) do
    """


    Left alone: each of these is reached through a symlink and really lives
    somewhere else, so removing it would take a file out of whatever repo owns
    it:

    #{Enum.map_join(linked, "\n", &("  " <> &1))}
    """
    |> String.trim_trailing()
  end

  defp where(:repo), do: "from this repo"
  defp where(:global), do: "from ~/.claude"

  # A file whose contents are already what we would write is left alone, mtime
  # and all. `whiska doctor` reads the main session's age against when its
  # wiring last changed (Claude Code loads hooks once, at startup), and a
  # re-init that rewrote identical bytes would make every live session look
  # stale when nothing had moved.
  defp write_unchanged(path, contents) do
    case File.read(path) do
      {:ok, ^contents} -> :ok
      _different_or_missing -> File.write(path, contents)
    end
  end

  @mode 0o755

  # `File.chmod/2` writes the whole file_info record back, mtime included, so an
  # unconditional chmod moves the clock exactly as a rewrite would — the thing
  # `write_unchanged/2` above is there to avoid. The whole mode is compared, not
  # the execute bits: a shim left group- or world-writable is exactly what
  # re-running `init` is supposed to put right, and a mode that really is wrong
  # is a change, so moving its clock is honest.
  defp make_executable(path) do
    case File.stat(path) do
      {:ok, %File.Stat{mode: mode}} when Bitwise.band(mode, 0o7777) == @mode -> :ok
      _wrong_or_missing -> File.chmod(path, @mode)
    end
  end

  defp write_statusline(repo_root) do
    script = Path.join(repo_root, Install.statusline_path())

    with :ok <- File.mkdir_p(Path.dirname(script)),
         :ok <- write_unchanged(script, Install.statusline_script()) do
      make_executable(script)
    end
  end

  defp write_skills(scope, root) do
    Enum.reduce_while(Install.skills(scope), :ok, fn {rel, body}, :ok ->
      file = Path.join(root, rel)

      # The target's directory, not the link's: a link left behind after its
      # dotfiles file was deleted is written through like any other.
      with :ok <- File.mkdir_p(Path.dirname(file)),
           :ok <- File.mkdir_p(Path.dirname(Layout.canonical(file))),
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
  defp write_claude_md(scope, root) do
    path = claude_md_path(scope, root)

    existing =
      case File.read(path) do
        {:ok, contents} -> contents
        {:error, :enoent} -> ""
      end

    case ClaudeMd.merge(existing, scope) do
      ^existing -> :ok
      merged -> with :ok <- File.mkdir_p(Path.dirname(path)), do: File.write(path, merged)
    end
  end

  defp claude_md_path(:repo, root), do: Path.join(root, "CLAUDE.md")
  defp claude_md_path(:global, root), do: Path.join(root, ".claude/CLAUDE.md")

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
  defp watch(cwd) do
    case main_checkout(cwd) do
      {:ok, main} ->
        board(main)

      :error ->
        IO.puts(
          :stderr,
          "whiska: #{cwd} is not a git checkout, and not inside a worktree of one."
        )

        1
    end
  end

  # The board, computed now rather than read from the file the owl keeps
  # (ADR-0051) — this is what somebody runs when the statusline looks wrong.
  defp board(main) do
    case Whiska.Watch.house(main) do
      {:ok, board} ->
        case Whiska.Watch.render(board) do
          "" -> 0
          lines -> say(lines)
        end

      {:error, reason} ->
        IO.puts(:stderr, "whiska: could not reach this repo's house (#{inspect(reason)}).")
        1
    end
  end

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

  # The flip still works — it is also how a mouse nobody shaped gets a mode —
  # but one that moves a mouse off its shape says what it carried along: the
  # model and effort chosen for the other mode's work, which stay until the
  # process ends (ADR-0074).
  defp set_mode(mouse_id, layout, mode) do
    case Storage.set_mode(mouse_id, mode) do
      {:ok, mouse} ->
        ignore_spec(layout)
        say("#{layout.branch_label} is now a #{mode} mouse." <> carried(mouse))

      {:error, reason} ->
        IO.puts(:stderr, "whiska: could not set the mode (#{inspect(reason)}).")
        1
    end
  end

  defp carried(mouse) do
    case Whiska.Shape.moved_from(mouse) do
      nil ->
        ""

      as ->
        " It keeps #{mouse.model || "your default model"} at " <>
          "#{mouse.effort || "your default"} effort, chosen when it was shaped as #{as}; " <>
          "`whiska mice` shows that while it runs."
    end
  end

  # stdout is the flags to start Claude with — plain words only, or nothing —
  # so a spawn can split them straight into `claude`'s arguments; what was
  # recorded goes to stderr, for the person.
  defp shape(mouse_id, layout, %{mode: mode, model: model, effort: effort} = shape) do
    case Storage.shape(mouse_id, mode, model, effort) do
      {:ok, _} ->
        IO.puts(:stderr, "#{layout.branch_label} is #{Whiska.Shape.describe(shape)}.")
        ignore_spec(layout)
        say(Enum.join(Whiska.Shape.claude_args(shape), " "))

      {:error, reason} ->
        IO.puts(:stderr, "whiska: could not shape this mouse (#{inspect(reason)}).")
        1
    end
  end

  # Shaping, or setting the mode of a mouse nobody shaped, comes before the
  # mouse can write a spec. A failure does not stop either: the mouse says so
  # under its spec, and until then the owl only leaves the worktree standing.
  defp ignore_spec(layout) do
    with {:error, reason} <- Whiska.Spec.ignore(layout.main_checkout) do
      IO.puts(
        :stderr,
        "whiska: could not make git ignore #{Whiska.Spec.filename()} (#{inspect(reason)})."
      )
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
  # yields to the supervised one: if the service manager has an owl up, this
  # one refuses — unless that owl *is* this process. The wrapper execs, so the
  # job's pid is this BEAM's own pid, and without that test the supervised owl
  # refuses itself, exits 1, and is restarted into a loop (ADR-0040,
  # 2026-09-28 note). A manager that is not there at all has no owl up.
  defp not_supervised do
    manager = ServiceManager.impl()

    case manager.status() do
      %{loaded: true, pid: pid} when is_integer(pid) ->
        if pid == os_pid(), do: :ok, else: refuse_to_supervised(manager, pid)

      _ ->
        :ok
    end
  end

  defp os_pid, do: String.to_integer(System.pid())

  defp refuse_to_supervised(manager, pid) do
    IO.puts(
      :stderr,
      "whiska: the owl is already running under #{manager.name()} (pid #{pid}). " <>
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

  # Under a service manager there is no pane's environment to inherit, so a
  # missing HERDR_SOCKET_PATH falls back to herdr's default socket rather than
  # to no herdr at all; the job carries the variable when it was set at install.
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

  # Nothing to open is not an error: the service manager starts the owl from
  # the home directory, and before the first `whiska owl <repo>` there is
  # nothing in the record. The owl idles until a house is opened rather than
  # exiting, which under a restart-on-crash job would be a loop (ADR-0040).
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

  defp start(cwd, force?, claude?) do
    with {:ok, pane} <- current_pane(),
         {:ok, main} <- main_checkout_only(cwd) do
      with_house(main, fn ->
        case Storage.main_pane() do
          ^pane ->
            say("#{pane} is already the main session for #{Path.basename(main)}.")
            start_claude(pane, claude?)

          nil ->
            record_main(main, pane)
            start_claude(pane, claude?)

          other ->
            if force? or not running_claude?(other) do
              record_main(main, pane)
              start_claude(pane, claude?)
            else
              refuse_to_replace(other)
            end
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

  # The second half of `whiska start` (ADR-0066): the pane is recorded, and a
  # pane with no Claude Code in it has nothing to deliver into, so the command
  # starts one rather than leaving the person a second command to remember.
  #
  # The pane is recorded first because this is the last thing that happens
  # here — whiska is itself what is running in that pane, and starting Claude
  # means handing the pane over and getting out of the way. The line is typed
  # at the shell prompt and waits there until this process exits.
  defp start_claude(pane, claude?) do
    cond do
      running_claude?(pane) -> 0
      not claude? -> say("Nothing is delivered until Claude Code is running in this pane.")
      true -> run_claude(pane)
    end
  end

  # With no herdr to ask, neither half of this is knowable: whether Claude is
  # already running in the pane, and whether it could be started. The pane is
  # recorded either way, and saying so is the whole of what is left to do —
  # not a failure, because nothing was attempted and failed.
  defp run_claude(pane) do
    case Herdr.socket() do
      {:ok, socket} ->
        case Herdr.impl().run_command(socket, pane, "claude") do
          :ok -> say("Starting Claude Code here.")
          {:error, reason} -> could_not_start(pane, reason)
        end

      {:error, {:no_socket, _default}} ->
        say(
          "Could not reach herdr to start Claude Code; start it here yourself if it is not running."
        )
    end
  end

  # The recording stands: it is the fact the person asked for, re-running the
  # command is harmless, and `whiska doctor` says the same thing afterwards —
  # a main session recorded with no Claude in it holds its questions rather
  # than losing them.
  defp could_not_start(pane, reason) do
    fail("""
    whiska: #{pane} is recorded as the main session, but Whiska
    could not start Claude Code in it (#{inspect(reason)}).

    Start it yourself in this pane; nothing is delivered until it is running.
    """)
  end

  defp refuse_to_replace(other) do
    fail("""
    whiska: #{other} is already this repo's main session, and is still running Claude.

    Two main sessions would fight over the same questions. If that one is stale,
    or you mean to move the main session here, run `whiska start --force`.
    """)
  end

  defp running_claude?(pane) do
    case Herdr.socket() do
      {:ok, socket} -> match?({:ok, %{agent: "claude"}}, Herdr.impl().pane(socket, pane))
      {:error, {:no_socket, _default}} -> false
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

  # A mouse's own session draws no board (ADR-0051), and this refuses there
  # rather than leaving it to the script, so a repo still carrying the script an
  # older `whiska init` wrote does not put the board in every mouse's pane.
  # Always 0 and never noisy, whatever it finds: this runs on a timer wherever a
  # session is sitting, and a statusline is no place to report a broken house.
  defp statusline_here(cwd) do
    with {:error, :not_in_worktree} <- Layout.resolve(cwd),
         {:ok, main} <- main_checkout(cwd),
         {:ok, board} <- Whiska.Watch.house(main),
         lines when lines != "" <- Whiska.Watch.render(board) do
      IO.puts(lines)
    end

    0
  end

  # -- worktrees ---------------------------------------------------------------

  defp worktrees(cwd) do
    with {:ok, socket} <- herdr_socket(),
         {:ok, trees} <- Herdr.impl().worktrees(socket, cwd),
         {:ok, panes} <- Herdr.impl().list_panes(socket) do
      case trees do
        [] ->
          say("No linked worktrees.")

        _ ->
          trees
          |> Enum.map(&worktree_line(&1, panes))
          |> Enum.each(&IO.puts/1)
          |> then(fn _ -> 0 end)
      end
    else
      {:error, {:no_socket, default}} -> no_socket(default, "list worktrees from")
      {:error, reason} -> fail("whiska: could not ask herdr for worktrees (#{describe(reason)}).")
    end
  end

  defp worktree_line(%{branch: branch, path: path, workspace_id: workspace}, panes) do
    pane = workspace && Enum.find(panes, &(&1.workspace_id == workspace))

    [branch || "-", path, workspace || "-", pane && pane.pane_id, pane && pane.agent_status]
    |> Enum.map_join("\t", &(&1 || "-"))
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
  # loaded by id, without its mouse, so the mouse is looked up here.
  defp show_question(%Question{} = q) do
    mode = Mode.read()
    slot = Mode.slot(Storage.questions(), mode)
    focus = if mode.focus, do: Questions.who(Storage.mouse(mode.focus), mode.focus)

    say(
      Questions.full(q, Questions.who(Storage.mouse(q.mouse_id), q.mouse_id), slot, mode, focus)
    )
  end

  # -- away, focus, hold and resume (ADR-0079)

  defp inbox(:json), do: say(Waiting.json(Waiting.list()))
  defp inbox(:text), do: say(Waiting.render(Waiting.list(), away?: Mode.away?()))

  defp away do
    was_away = Mode.away?()

    case Mode.set_away() do
      :ok when was_away ->
        say("You were already away. Nothing is delivered anywhere until `resume`.")

      :ok ->
        say(
          "Away. Nothing is delivered to any main session until `resume`; " <>
            "mice keep working, and `inbox` keeps listing what they ask."
        )

      {:error, reason} ->
        fail("whiska: could not write #{Mode.away_path()} (#{inspect(reason)}).")
    end
  end

  defp show_focus do
    case Storage.focus() do
      nil ->
        say("No focus: every mouse's questions reach the main session.")

      mouse_id ->
        say(
          "Focus: #{name_of(mouse_id)}. Only its questions reach the main session; " <>
            "the rest wait, and `inbox` lists them. `resume` ends it."
        )
    end
  end

  defp set_focus(branch) do
    with {:ok, mouse} <- live_mouse_on(branch) do
      :ok = Storage.set_focus(mouse.mouse_id)

      say(
        "Focus: #{branch}. Only its questions reach the main session now; the rest wait, " <>
          "and `inbox` still lists them. `resume` ends it." <> away_note()
      )
    end
  end

  defp away_note do
    if Mode.away?(),
      do: " You are away, so nothing is delivered until `resume` — which ends this focus too.",
      else: ""
  end

  defp hold(branch) do
    with {:ok, mouse} <- live_mouse_on(branch),
         {:ok, _} <- Storage.hold(mouse.mouse_id) do
      say(
        "#{branch} is on hold: its next tool call is refused, nothing of its is delivered, " <>
          "and it is not offered for landing. `resume #{branch}` lifts it."
      )
    end
  end

  # Away is the machine's; the focus is this repo's when the command runs in
  # one, and every recorded repo's when it runs outside any.
  defp resume(cwd) do
    was_away = Mode.away?()
    :ok = Mode.clear_away()

    case main_checkout(cwd) do
      {:ok, main} ->
        if File.exists?(Storage.database_path(main)) do
          with_house(main, fn ->
            case end_focus() do
              nil -> say(resumed(was_away, []))
              branch -> say(resumed(was_away, ["focus on #{branch} ended"]))
            end
          end)
        else
          say(resumed(was_away, []))
        end

      :error ->
        say(resumed(was_away, every_focus_ended()))
    end
  end

  defp end_focus do
    case Storage.focus() do
      nil ->
        nil

      mouse_id ->
        :ok = Storage.set_focus(nil)
        name_of(mouse_id)
    end
  end

  defp every_focus_ended do
    OpenHouses.read()
    |> Enum.filter(&File.exists?(Storage.database_path(&1)))
    |> Enum.flat_map(fn main ->
      case Storage.open(main) do
        {:ok, handle} ->
          try do
            case end_focus() do
              nil -> []
              branch -> ["#{Path.basename(main)}: focus on #{branch} ended"]
            end
          after
            Storage.close(handle)
          end

        {:error, _} ->
          []
      end
    end)
  end

  defp resumed(false, []), do: "Nothing was set aside; everything already flows."

  defp resumed(was_away, ended) do
    said = if(was_away, do: ["away ended"], else: []) ++ ended
    "Resumed: #{Enum.join(said, "; ")}. What waited arrives oldest first."
  end

  # The line goes only to a mouse that stopped because of the hold — its latest
  # question was asked after the stamp. One that was waiting on the person's
  # answer when held must not run on without it.
  defp resume_branch(branch) do
    with {:ok, mouse} <- live_mouse_on(branch) do
      case mouse.held_at do
        nil ->
          say("#{branch} is not on hold.")

        held_at ->
          {:ok, _} = Storage.lift_hold(mouse.mouse_id)
          carry_on(mouse, branch, held_at, Storage.latest_question(mouse.mouse_id))
      end
    end
  end

  # A question asked after the stamp is the stop the hold caused: the carry-on
  # line answers it, so it is never delivered as a decision once the hold is
  # gone. A `done` after the stamp is a mouse that finished anyway, and its
  # finished line is what the person hears now. Anything older was there
  # before the hold and is the person's to answer.
  defp carry_on(mouse, branch, held_at, %Question{asked_at: asked_at} = latest)
       when is_struct(asked_at, DateTime) do
    cond do
      DateTime.compare(asked_at, held_at) == :gt and latest.kind == "done" ->
        say("Hold on #{branch} lifted. It had finished, so its finished line is told now.")

      DateTime.compare(asked_at, held_at) == :gt ->
        type_carry_on(mouse, branch, latest)

      latest.status in ["open", "sent"] ->
        say(
          "Hold on #{branch} lifted. Its question ##{latest.id} is still waiting on you: " <>
            "`reply #{latest.id} <your answer>`."
        )

      true ->
        say("Hold on #{branch} lifted.")
    end
  end

  defp carry_on(_mouse, branch, _held_at, nil), do: say("Hold on #{branch} lifted.")

  defp type_carry_on(%Mouse{pane: nil}, branch, _stop) do
    IO.puts("Hold on #{branch} lifted.")

    fail(
      "whiska: #{branch} has no pane recorded, so nothing was typed into it. " <>
        "Its last message is delivered as a question; `reply` to that."
    )
  end

  defp type_carry_on(mouse, branch, stop) do
    with {:ok, socket} <- herdr_socket(),
         :ok <- Herdr.impl().prompt(socket, mouse.pane, Mode.resume_line()) do
      if stop.status in ["open", "sent"], do: Storage.answer(stop.id, Mode.resume_line())
      Storage.set_working(mouse.mouse_id, DateTime.utc_now())
      say("Hold on #{branch} lifted; told it to carry on from where it stopped.")
    else
      {:error, {:no_socket, default}} ->
        IO.puts("Hold on #{branch} lifted.")
        no_socket(default, "reach the mouse's pane through")

      {:error, reason} ->
        IO.puts("Hold on #{branch} lifted.")

        fail(
          "whiska: could not tell #{branch} to carry on (#{describe(reason)}). " <>
            "Type into its pane yourself, or `reply` to its next question."
        )
    end
  end

  defp live_mouse_on(branch) do
    case Enum.find(Storage.alive_mice(), &(&1.branch == branch)) do
      %Mouse{} = mouse ->
        {:ok, mouse}

      nil ->
        fail(
          "whiska: no live mouse of this repo is on #{branch}. " <>
            "`whiska mice` lists the ones there are."
        )
    end
  end

  defp name_of(mouse_id) do
    case Storage.mouse(mouse_id) do
      %Mouse{branch: branch} when is_binary(branch) -> branch
      _ -> mouse_id
    end
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
         :ok <- lift_hold_for_answer(mouse),
         :ok <- Herdr.impl().prompt(socket, mouse.pane, text),
         {:ok, _} <- Storage.answer(q.id, text) do
      # An answer is a prompt, and a prompt is a turn beginning. Recording it
      # here is what lets the owl pick that turn up if it dies while the owl
      # is down and never sees the pane working (ADR-0067).
      Storage.set_working(mouse.mouse_id, DateTime.utc_now())
      say("Answered ##{q.id} (#{mouse.branch}): typed into #{mouse.pane}." <> lifted(mouse))
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

  # Answering a held mouse is picking it up: a hold left in place would have the
  # hook refuse the very turn the answer starts.
  defp lift_hold_for_answer(%Mouse{held_at: %DateTime{}} = mouse) do
    with {:ok, _} <- Storage.lift_hold(mouse.mouse_id), do: :ok
  end

  defp lift_hold_for_answer(_mouse), do: :ok

  defp lifted(%Mouse{held_at: %DateTime{}, branch: branch}),
    do: " The hold on #{branch} is lifted."

  defp lifted(_mouse), do: ""

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
  # shell environment at all, which is the same position the supervised owl is in.
  defp herdr_socket, do: Herdr.socket()

  defp no_socket(default, cannot) do
    fail(
      "whiska: HERDR_SOCKET_PATH is not set and there is no socket at herdr's default, " <>
        "#{default} — so there is no herdr to #{cannot}. Is herdr running?"
    )
  end

  defp describe({:herdr, %{"code" => code, "message" => message}}), do: "#{code}: #{message}"
  defp describe(reason) when is_binary(reason), do: reason

  defp describe({:control_character, name}),
    do: "#{name} holds a control character, which would end a line of the unit"

  defp describe(reason), do: inspect(reason)

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

  # -- the owl under its service manager (ADR-0040) -------------------------------
  # launchd on macOS, systemd on Linux (ADR-0077);
  # the verbs mean the same on both.

  defp owl_install do
    manager = ServiceManager.impl()
    env = Application.get_env(:whiska, :env) || System.get_env()

    with :ok <- manager_ready(manager),
         paths = manager.paths(),
         status = manager.status(),
         :ok <- no_other_owl(manager, status),
         :ok <- Install.write_herdr_status(),
         :ok <- manager.install(paths, env),
         :ok <- manager.load(paths, status) do
      if env["HERDR_SOCKET_PATH"] in [nil, ""] do
        IO.puts(
          :stderr,
          "whiska: HERDR_SOCKET_PATH is not set here, so the #{manager.noun()} does not carry it; " <>
            "the owl will use herdr's default, #{Herdr.default_socket_path(env)}. " <>
            "Run this from a herdr pane to pin it."
        )
      end

      say("""
      Installed #{manager.label()} and started the owl under #{manager.name()}.

        job:     #{paths.job}
        runs:    #{paths.wrapper}  (whiska owl, no arguments — reopens the recorded houses)
        log:     #{paths.log}

      #{manager.name()} starts it at login and restarts it if it crashes. `whiska owl stop`
      turns it off until `whiska owl start`, or until #{manager.name()} next starts
      your user session; `whiska owl uninstall` removes it. `whiska doctor` shows
      its state.
      #{linger_note(manager.linger())}
      Also wrote #{Install.herdr_status_path()}, the script herdr's tab bar runs
      to draw the owl's line (ADR-0048). Nothing wires it for you — herdr's
      config is yours. Paste this into #{Whiska.Herdr.config_path()} and commit
      it with your dotfiles:

      #{Install.tab_bar_right_snippet()}
      Then `herdr server reload-config`. `whiska doctor` says whether it took.
      """)
    else
      {:error, :owl_running} ->
        1

      {:error, {:not_ready, reason}} ->
        fail("""
        whiska: #{reason}.
        Run `whiska owl` in a pane instead: it works the same, and stops with the pane.
        """)

      {:error, reason} ->
        fail("whiska: could not install the #{manager.noun()} (#{describe(reason)}).")
    end
  end

  defp manager_ready(manager) do
    case manager.ready() do
      :ok -> :ok
      {:error, reason} -> {:error, {:not_ready, reason}}
    end
  end

  # systemd stops a user's services at logout unless lingering is on, and
  # turning it on is a machine setting, so install only says how.
  defp linger_note(false) do
    """

    systemd stops it when you log out. To keep it running after your last
    session ends, run `loginctl enable-linger` once.
    """
  end

  defp linger_note(_lingers_or_not_applicable), do: ""

  # Two owls collecting the same doorsteps is the one state install must
  # never produce, so it refuses while any owl is in the process table — the
  # supervised one included, since reinstalling means stopping it first.
  defp no_other_owl(manager, status) do
    case owl_pids() do
      [] ->
        :ok

      pids ->
        if status.pid in pids,
          do:
            fail("""
            whiska: the owl is already running under #{manager.name()} (pid #{status.pid}).
            To reinstall, `whiska owl stop` first, then `whiska owl install`.
            """),
          else:
            fail("""
            whiska: an owl is already running in the foreground (pid #{Enum.join(pids, ", ")}).
            Two owls would collect the same doorsteps. The handover is:

              1. Ctrl-C the foreground owl in its pane.
              2. `whiska owl install` again — #{manager.name()}'s owl reopens the same houses.
            """)

        {:error, :owl_running}
    end
  end

  defp owl_uninstall do
    manager = ServiceManager.impl()
    paths = manager.paths()
    status = manager.status()

    with :ok <- if(status.loaded, do: manager.unload(), else: :ok),
         :ok <- manager.uninstall(paths) do
      say(
        "Removed #{manager.label()}: the owl is no longer supervised. " <>
          "The log at #{paths.log} and the open-houses record are kept. " <>
          "`whiska owl install` puts it back."
      )
    else
      {:error, :not_installed} ->
        say("#{manager.label()} is not installed; nothing to remove.")

      {:error, reason} ->
        fail("whiska: could not remove the #{manager.noun()} (#{describe(reason)}).")
    end
  end

  defp owl_stop do
    manager = ServiceManager.impl()

    case manager.status() do
      %{loaded: false} ->
        fail(
          case owl_pids() do
            [] ->
              "whiska: #{manager.label()} is not installed, and no owl is running."

            pids ->
              "whiska: #{manager.label()} is not installed; the owl running (pid " <>
                "#{Enum.join(pids, ", ")}) is in the foreground — Ctrl-C it in its pane."
          end
        )

      %{pid: nil} ->
        say(
          "The owl is not running under #{manager.name()}; nothing to stop. " <>
            "`whiska owl start` starts it."
        )

      %{pid: pid} ->
        case manager.stop() do
          :ok ->
            say(
              "Asked the owl (pid #{pid}) to exit. It stays installed: #{manager.name()} " <>
                "starts it again when it next starts your user session, or now with " <>
                "`whiska owl start`."
            )

          {:error, reason} ->
            fail("whiska: could not stop the owl (#{reason}).")
        end
    end
  end

  defp owl_start do
    manager = ServiceManager.impl()

    case manager.status() do
      %{loaded: false} ->
        fail(
          "whiska: #{manager.label()} is not installed. `whiska owl install` installs and starts it."
        )

      %{pid: pid} when is_integer(pid) ->
        say("The owl is already running under #{manager.name()} (pid #{pid}).")

      _ ->
        case manager.start() do
          :ok -> say("Started the owl under #{manager.name()} (#{manager.label()}).")
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
