defmodule Whiska.CLI do
  @moduledoc """
  The `whiska` binary.

  Built with `mix escript.build`. The hooks invoke it fresh per event (ADR-0033):
  `PreToolUse` opens SQLite, makes one decision, and exits; `Stop` writes one
  doorstep entry and exits.
  `whiska owl` is the other half — the one supervised
  process per machine (ADR-0001), under the platform's service manager —
  launchd on macOS, systemd on Linux — once `whiska owl install` has run
  (ADR-0040), or in the foreground before that.
  """

  alias Whiska.Hook.PreToolUse
  alias Whiska.Hook.Stop
  alias Whiska.Hook.UserPromptSubmit
  alias Whiska.AnswerFlag
  alias Whiska.Delivery.Mode
  alias Whiska.Doctor
  alias Whiska.Doorbell
  alias Whiska.Doctor.Report
  alias Whiska.Ledger
  alias Whiska.Git
  alias Whiska.Herdr
  alias Whiska.Install
  alias Whiska.Layout
  alias Whiska.Marker
  alias Whiska.Metrics
  alias Whiska.OpenHouses
  alias Whiska.Questions
  alias Whiska.Review
  alias Whiska.Schema.Mouse
  alias Whiska.Schema.Question
  alias Whiska.ServiceManager
  alias Whiska.Sidebar
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
                         payload on stdin.

                         The hook shim asks the running owl first, over
                         ~/.whiska/hook.sock, and runs these only when the
                         owl does not answer.

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

    init                 Write Whiska's hooks into this repo's own .claude/, so
                         the rules travel with the repo, and take out what an
                         older Whiska wrote: its skills, its SessionStart hook
                         and its statusline. Safe to re-run.

    init --global        The same, into ~/.claude, for every repo on this
                         machine — for a repo that cannot carry a committed
                         .claude/ of its own. A repo that has run `whiska init`
                         still wins there; this copy stands down. Safe to
                         re-run, and it writes through a symlink rather than
                         replacing it, so a dotfiles repo stays connected.

    uninstall            Take Whiska back out of this repo: the hooks, the
    uninstall --global   scripts and any skills an older Whiska wrote. The
                         house — its mice, its questions, its doorstep — is
                         untouched. With --global, the same against ~/.claude.

    start [--force]      Record the herdr pane this is run from as the main
         [--no-claude]   session for this repo: where the owl delivers
                         questions. Run it in the main checkout, in the pane
                         you want your main Claude Code session in — and if
                         nothing is running there, it starts Claude Code for
                         you, with the main session's brief (written to
                         .git/whiska/main.md). From inside a session already
                         running, `! whiska start` records the pane and starts
                         nothing, and says to restart one started without it.
                         Refuses to replace a main session still running
                         Claude unless --force. --no-claude records the pane
                         and leaves starting Claude to you.

    questions [<id>]     What is waiting on you: one line per open or
    questions --full     delivered question, then any orphaned ones, then
                         what is still on the doorstep. With an id, that
                         question in full; with --full, every open one in
                         full, oldest first, so there is no id to type. A
                         report shows only its Summary, under its link.

    waiting [--json]     What is waiting on you anywhere on this machine: one
                         line per question, across every house the owl has
                         recorded (~/.whiska/houses), oldest first — repo,
                         branch, what the mouse said, how long it has waited,
                         its id and its herdr pane. Uncollected doorstep
                         entries are in it too. Run from anywhere; it is not
                         repo-scoped, and it reads whether or not the owl is
                         up. --json prints the same rows for a script.

    open <id|branch>     Take me to that mouse's own pane: focus it when it is
                         running, open its worktree in herdr when only the
                         worktree is left (no session starts there), or say
                         what remains — a kept branch with its commit count,
                         or that it landed or was dropped. Run from the repo.
                         Unlike `jump`, it lands in the mouse's pane, because
                         you asked for that mouse by name.

    jump [<repo|branch>] Take me to whatever needs me: focus the main session
                         of the house the oldest thing `whiska inbox` lists
                         belongs to. With a repo name, or a branch — whichever
                         house that mouse works in — focus that house's main
                         session instead, waiting or not. It lands on the
                         whiska, never on a mouse's pane: that is the pane the
                         question was delivered into and the one you answer
                         from. Prints where it went, or says nothing needs you.

                         HERDR_SOCKET_PATH is used when it is set, and herdr's
                         default socket (~/.config/herdr/herdr.sock) when it is
                         not — a hotkey runs with no shell environment at all.

                         For a global hotkey, bind a key in your hotkey tool
                         or your desktop's keyboard settings to a command that
                         brings your terminal forward and jumps; on macOS:

                           open -a <your terminal> && whiska jump

                         The hotkey's PATH must reach `whiska`; give its full
                         path if it does not.

    jump --list [--json] Every whiska `jump <repo>` can land on, one line each,
                         for a script such as an fzf popup: the ones waiting
                         on you first, longest wait on top, then quiet ones,
                         then any with no main session recorded. Fields split
                         by tabs: repo, main checkout, waiting count, oldest
                         wait in seconds (- when nothing waits), summary.
                         Held mice's questions are not counted. --json prints
                         the same fields as an array. `jump <main checkout>`
                         reaches a house by its path when two share a name.

    One word each, for handling questions. `whiska init --global` installs
    them as plain commands under ~/.whiska/bin, and as slash commands in the
    main session. The long names above keep working.

    inbox [--all] [--json]
                         What is waiting on you in this repo, oldest first —
                         the rows `waiting` prints, with why each is not being
                         delivered (held, away, focus: <branch>, queued
                         behind #<id>) and a first line when you are away.
                         `--all`, or outside any repo, lists every repo.
    show [<id>]          The question delivered to you, in full, or any one by
                         id; a report shows only its Summary, under its link.
                         Queued ones wait their turn: `inbox` lists them.
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
                         from anywhere. herdr's own script asks the running
                         owl for the same line over ~/.whiska/owl.sock and
                         starts nothing; `whiska doctor` prints the herdr
                         config entry that draws it.

    reply <id> <text>    Answer a question. The answer is saved and the
                         question marked answered; only a short doorbell line
                         is typed into that mouse's pane, and the mouse's own
                         hook hands the answer over. The owl rings again while
                         it is not taken.

    close <id>           Settle a question by hand, with no answer — for one
                         you dealt with some other way.

    The main session's commands for a branch. A mouse is refused them.

    spawn build|sniff <branch> <task-file> [--model <name>] [--effort <level>]
    spawn build|sniff <branch> --from <id> [--comments <file>] [...]
                         A fresh worktree at worktrees/<branch>, opened by
                         herdr in its own workspace without moving you there;
                         the mouse shaped (see `shape`), Whiska's hooks carried
                         in where the repo never committed them, Claude started
                         and handed the task in the file. --from builds what
                         question <id> proposes under "What to change", and
                         --comments hands the new mouse your comments on its
                         research document. The branch must be new: a-z, 0-9,
                         - and /, at most 32 characters.

    send <branch> <file> Your words in <file> to the mouse at work on <branch>:
                         copied into its worktree, and one line typed into its
                         pane pointing there. A mouse mid-turn reads it once
                         its turn ends. An answer to a question is `reply`.

    land <id> [--commit <message-file>]
                         Copy the commits of question <id>'s branch onto the
                         branch this checkout is on, oldest first, then run
                         the `checks:` this repo's CLAUDE.md names under
                         ## Finish. Files the mouse left uncommitted are
                         listed and nothing lands; --commit commits them first
                         with the message in that file. A clash lands nothing;
                         a failing check leaves the copies and says how to
                         take them back. The owl removes the worktree once the
                         work is in the base.

    pr <id> [--commit <message-file>]
                         Push question <id>'s branch by name and open a merge
                         request with gh (glab for a GitLab remote): the
                         mouse's message as its body, the branch's first
                         commit subject as its title. The link is recorded as
                         `merge-request` would. Once one is open, `pr` pushes
                         the branch's new commits to it instead.

    drop <branch> [--force]
                         Take down a branch that is not landing: its worktree,
                         its herdr workspace and the branch. Commits no remote
                         has and files not committed are listed and nothing
                         goes, unless --force.

    merge-request <id> <url>
                         Record the merge request just opened for the branch
                         of finished question <id>, by its https link. Its
                         later finished lines then say "merge request opened"
                         and offer pushing to it, and the owl fetches the base
                         branch until it lands. `whiska pr` records the one it
                         opens; this is for one opened by hand.

    ledger [--json]      Print the agent ledger a finished report ends with,
                         read from this Claude Code session's transcripts: one
                         line per agent sent this turn, then the mouse's whole
                         session — model, effort, new tokens (input, cache
                         writes, output), cache reads, steps, average per
                         step, tool uses, seconds. "≥" marks a lower bound.
                         --json prints the same figures as data. Run inside a
                         session; a sniff mouse may run it too.

    metrics [--json]     What this repo's house says about cost and waiting,
                         in four views: cost by shape (mode, model and effort
                         a mouse's turns ran on), waits (asked, delivered,
                         answered, taken), spec timing, and agent cost by
                         reviewer axis. Tokens only, weighed into cost units
                         (input + 1.25 × cache writes + 0.1 × cache reads +
                         5 × output). Usage is recorded by the owl for each
                         turn it collects; --json prints the same views as
                         data.

    mice                 List what is alive in this repo's house: one line per
                         mouse — branch, mode, what its pane is doing, how full
                         its context is, uptime.

    watch                Print the lines herdr's sidebar shows for this repo,
                         worked out now: the main checkout's, then each mouse
                         under its branch — what it needs from you, else what
                         it is doing. The owl writes them every second; run
                         this when the sidebar looks wrong.

    doctor               Is Whiska working for this repo right now? Checks the
                         binary, runtime, herdr, owl, this repo's hooks and
                         shim (by running them), its house, doorstep and mice.
                         Prints a fix for each finding; changes nothing. Exits
                         1 if anything failed.

    worktrees            List this repo's linked worktrees as tab-separated
                         lines: branch, path, herdr workspace id, the id of the
                         pane in it, and what that pane is doing. A dash where
                         there is no workspace open. The main session reads it
                         before it routes a task.

    where                For scripts and hooks: where this directory is, as
                         one line of JSON. Always exits 0. The fields are a
                         stable interface; a change to them bumps "version".
                           version         1
                           worktree        this worktree's root folder
                           branch          its whole branch name, as feat/x
                           main_checkout   the main checkout's folder
                           main_workspace  herdr workspace id open on the
                                           main checkout; null when herdr
                                           takes over half a second
                         Every field is always present; one with no answer is
                         null. In the main checkout, worktree and branch are
                         null. Outside a Whiska worktree or main checkout, all
                         four are null. Read one with
                         jq -r '.main_workspace // empty'.

    mode                 Print this mouse's mode. A mode reaches Claude only
                         as its launch flags: to give one to a mouse nobody
                         shaped, run `shape` in its worktree and restart
                         Claude there with the flags it prints.

    shape build|sniff [--model <name>] [--effort <level>]
                         Give a fresh mouse its shape, before Claude starts
                         (ADR-0069): record its mode, model and effort, write
                         its mode's brief to .whiska-brief.md and its deny
                         list to .whiska-settings.json, and print the flags
                         to start Claude with: both files, and
                         --dangerously-skip-permissions, so Claude asks for
                         nothing the deny list allows. A
                         build mouse also gets --autocompact, its model's
                         window from priv/models.json. `spawn` does all this
                         itself; this is for a mouse started by hand.
                         Also makes git ignore the worktree's .whiska-spec.md,
                         .whiska-research.md, .whiska-plan.md, the brief and
                         the deny list, and clones
                         deps, _build and node_modules (plus the paths in
                         .git/whiska/clone, or nothing for a lone `off`) from
                         the main checkout copy-on-write, saying on stderr
                         what it did; that never fails the shape.
                         Fails rather than guess, so a spawn stops before
                         Claude. A mouse already shaped keeps its mode: another
                         mode is refused (ADR-0074), as is a link at either
                         file's path. A model or effort left out is the last rule's
                         in priv/models.json: #{@catch_all}.
    shape --rules        Print priv/models.json as this build carries it: the
                         modes, the ordered rules a spawn chooses a model and
                         an effort by, and the auto-compact window per model.

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

  def run(["hook", "user-prompt-submit"], _cwd) do
    stdin() |> UserPromptSubmit.run() |> emit()
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

  def run(["statusline", "--here"], _cwd), do: statusline_here()

  def run(["waiting"], _cwd), do: waiting(:text)
  def run(["waiting", "--json"], _cwd), do: waiting(:json)

  def run(["jump"], _cwd), do: jump_to_oldest()
  def run(["jump", "--list"], _cwd), do: jump_list(&Waiting.render_whiskas/1)
  def run(["jump", "--list", "--json"], _cwd), do: jump_list(&Waiting.whiskas_json/1)
  def run(["jump", name], _cwd), do: jump_to_name(name)

  def run(["open", target], cwd), do: open_mouse(cwd, target)

  def run(["inbox"], cwd), do: inbox(:text, :here, cwd)
  def run(["inbox", "--json"], cwd), do: inbox(:json, :here, cwd)
  def run(["inbox", "--all"], cwd), do: inbox(:text, :all, cwd)
  def run(["inbox", "--all", "--json"], cwd), do: inbox(:json, :all, cwd)
  def run(["inbox", "--json", "--all"], cwd), do: inbox(:json, :all, cwd)
  def run(["show"], cwd), do: with_house(cwd, fn -> show_delivered(cwd) end)
  def run(["show", id], cwd), do: with_question(cwd, id, &show_question(&1, cwd))
  def run(["dismiss", id], cwd), do: with_question(cwd, id, &close/1)
  def run(["away"], _cwd), do: away()
  def run(["focus"], cwd), do: with_house(cwd, &show_focus/0)
  def run(["focus", branch], cwd), do: with_house(cwd, fn -> set_focus(branch) end)
  def run(["hold", branch], cwd), do: with_house(cwd, fn -> hold(branch) end)
  def run(["resume"], cwd), do: resume(cwd || File.cwd!())
  def run(["resume", branch], cwd), do: with_house(cwd, fn -> resume_branch(branch) end)

  def run(["questions", id], cwd), do: with_question(cwd, id, &show_question(&1, cwd))

  def run(["reply", id, first | rest], cwd),
    do: with_question(cwd, id, &reply(&1, Enum.join([first | rest], " ")))

  def run(["close", id], cwd), do: with_question(cwd, id, &close/1)

  def run(["merge-request", id, url], cwd),
    do: with_question(cwd, id, &record_merge_request(&1, url))

  def run(["ledger"], _cwd), do: ledger(&Ledger.render/1)
  def run(["ledger", "--json"], _cwd), do: ledger(&Ledger.json/1)

  def run(["metrics"], cwd), do: with_house(cwd, fn -> say(Metrics.render(Metrics.read())) end)

  def run(["metrics", "--json"], cwd),
    do: with_house(cwd, fn -> say(Metrics.json(Metrics.read())) end)

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

  def run(["where"], cwd), do: where_am_i(cwd || File.cwd!())

  def run(["mode"], cwd), do: with_mouse(cwd, &show_mode/2)

  def run(["base"], cwd), do: with_mouse(cwd, &show_base/2)

  def run(["mode", mode], cwd) when mode in ["build", "sniff"],
    do: with_mouse(cwd, &refuse_mode(&1, &2, mode))

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

  def run(["spawn" | args], cwd), do: spawn(cwd, args)

  def run(["send", branch, file], cwd),
    do: with_herdr(cwd, "send to a mouse", &Whiska.Send.run(&1, branch, file, &2))

  def run(["drop", branch], cwd),
    do: with_herdr(cwd, "drop a worktree in", &Whiska.Drop.run(&1, branch, false, &2))

  def run(["drop", branch, "--force"], cwd),
    do: with_herdr(cwd, "drop a worktree in", &Whiska.Drop.run(&1, branch, true, &2))

  def run(["land", id], cwd), do: with_question(cwd, id, &land(&1, cwd, nil))
  def run(["land", id, "--commit", file], cwd), do: with_question(cwd, id, &land(&1, cwd, file))

  def run(["pr", id], cwd), do: with_question(cwd, id, &pr(&1, cwd, nil))
  def run(["pr", id, "--commit", file], cwd), do: with_question(cwd, id, &pr(&1, cwd, file))

  def run(["--version"], _cwd), do: say(@version)
  def run(["-v"], _cwd), do: say(@version)
  def run(["--help"], _cwd), do: say(String.trim_trailing(@usage))
  def run(["help"], _cwd), do: say(String.trim_trailing(@usage))

  def run(_argv, _cwd) do
    IO.write(:stderr, @usage)
    1
  end

  defp ledger(format) do
    with {:session, id} when is_binary(id) and id != "" <-
           {:session, System.get_env("CLAUDE_CODE_SESSION_ID")},
         path when is_binary(path) <- Ledger.find(id, ServiceManager.user_home()) do
      say(format.(Ledger.read(path)))
    else
      {:session, _unset} ->
        IO.puts(
          :stderr,
          "whiska: CLAUDE_CODE_SESSION_ID is not set — run this inside Claude Code."
        )

        1

      nil ->
        IO.puts(:stderr, "whiska: no transcript for this session under ~/.claude/projects.")
        1
    end
  end

  defp say(message) do
    IO.puts(message)
    0
  end

  defp init(scope, root) do
    path = Path.join(root, ".claude/settings.json")
    shim = Path.join(root, Install.shim_path())

    with {:ok, settings} <- read_settings(path),
         base = read_base_statusline(scope, root),
         merged = Install.merge(settings, scope, base),
         :ok <- File.mkdir_p(Path.dirname(shim)),
         :ok <- write_unchanged(shim, Install.shim(scope)),
         :ok <- make_executable(shim),
         retired = remove_retired_skills(root),
         {:ok, commands} <- write_commands(scope),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- write_unchanged(path, JSON.encode!(merged) |> reformat()) do
      statusline = retire_statusline(scope, root, settings, merged)

      say(
        told(scope) <>
          statusline_note(statusline) <>
          retired_note(retired, scope) <>
          commands_note(commands)
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

  # A skill an older Whiska wrote goes, deleted outright, where it is a plain
  # file of Whiska's. One reached through a symlink is the person's (ADR-0056):
  # it stays, and is named so it can be deleted where it lives. A folder goes
  # once nothing else is in it.
  defp remove_retired_skills(root) do
    removed = Install.retired_skills(root)

    for rel <- removed do
      File.rm(Path.join(root, rel))
      File.rmdir(Path.dirname(Path.join(root, rel)))
    end

    linked =
      Enum.filter(
        Install.retired_skills(),
        &(File.exists?(Path.join(root, &1)) and through_link?(root, &1))
      )

    {removed |> Enum.map(&(&1 |> Path.dirname() |> Path.basename())) |> Enum.uniq(), linked}
  end

  defp retired_note({[], linked}, _scope), do: linked_note(linked)

  defp retired_note({names, linked}, scope) do
    "\n\nRemoved the skills an older Whiska wrote, which nothing reads now: " <>
      Enum.join(names, ", ") <>
      ". Each session's brief carries what they said." <>
      commit_removal(scope) <> linked_note(linked)
  end

  # A repo's skills were committed, so every worktree cut from it keeps them
  # until the removal is.
  defp commit_removal(:repo),
    do: " If git tracked them, commit their removal too: `git add -A .claude/skills`."

  defp commit_removal(:global), do: ""

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

  # The Claude Code statusline an older init wrote goes, once settings that do
  # not name it are safely on disk: the script, and the line a global
  # install kept beside it, which is back in `settings.json` by now. A file
  # reached through a symlink is the person's and stays.
  defp retire_statusline(scope, root, before, merged) do
    {linked, removable} =
      [Install.statusline_path() | base_statusline(scope)]
      |> Enum.filter(&File.regular?(Path.join(root, &1)))
      |> Enum.split_with(&through_link?(root, &1))

    for rel <- removable, do: File.rm(Path.join(root, rel))

    entry? = before["statusLine"] != merged["statusLine"]

    %{
      removed: removable,
      linked: linked,
      entry?: entry?,
      restored: entry? && merged["statusLine"]
    }
  end

  defp statusline_note(%{removed: [], linked: [], entry?: false}), do: ""

  defp statusline_note(%{removed: removed, linked: linked, entry?: entry?, restored: restored}) do
    taken = if(entry?, do: ["settings.json statusLine"], else: []) ++ removed
    took_out(taken, restored) <> linked_note(linked)
  end

  defp took_out([], _restored), do: ""

  defp took_out(taken, restored) do
    back =
      case restored do
        %{"command" => command} -> "\n\nYour own statusline is back in settings.json: #{command}"
        _ -> ""
      end

    """


    Took out the Claude Code statusline an older init wrote:

    #{Enum.map_join(taken, "\n", &("  " <> &1))}

    Each mouse's state is a line in herdr's sidebar now, written by the owl.
    `whiska doctor` prints the herdr config that draws it.
    """
    |> String.trim_trailing()
    |> Kernel.<>(back)
  end

  defp linked_note([]), do: ""

  defp linked_note(linked) do
    "\n\nLeft alone, because it is reached through a symlink and lives somewhere " <>
      "else — delete it there:\n\n" <> Enum.map_join(linked, "\n", &("  " <> &1))
  end

  defp told(:repo) do
    """
    Wrote Whiska's hooks to .claude/settings.json — PreToolUse, Stop and
    UserPromptSubmit. PreToolUse is the one that enforces:

      matcher: #{Install.matcher()}
      command: #{Install.command()}

    The shim it calls went to #{Install.shim_path()}. That is where the Whiska
    binary and the Erlang runtime get resolved, when the hook fires — so
    neither file names anything specific to this machine.

    What each mouse is doing is drawn in herdr's sidebar, under its own
    workspace, and the owl's state on herdr's tab bar (ADR-0048). The owl
    writes both; `whiska doctor` prints the herdr config that draws them.

    Each session's rules come on its launch line: `whiska start` starts the
    main session with its brief, and `whiska spawn` each mouse with its own.

    Tell Whiska what green means here: a `## Finish` heading in CLAUDE.md with
    a `checks:` line naming this repo's checks, which `whiska land` runs once
    it has landed a branch.

    Check them into git so the rules travel with the repo (ADR-0056):

      git add .claude/settings.json .claude/hooks
      git commit -m "chore: enable whiska"
    """
    |> String.trim()
    |> then(&(&1 <> global_note()))
  end

  defp told(:global) do
    """
    Wrote Whiska into ~/.claude, for every repo on this machine.

    #{written()}

    Nothing else is needed per repo. The hooks work out for themselves which
    worktree they are firing in — so a repo that cannot carry a committed
    `.claude/` is covered by this and by its house alone.

    Per repo there is still one thing worth writing: a `## Finish` heading in
    that repo's own CLAUDE.md with a `checks:` line naming its checks, which
    `whiska land` runs once it has landed a branch.

    A repo that has run `whiska init` keeps winning — its own hooks are the
    ones in force, and this copy stands down there. To hand a
    repo over to this one instead, run `whiska uninstall` inside it and commit
    what that removes.
    """
    |> String.trim()
    |> then(&(&1 <> through_links()))
  end

  defp written do
    [
      {"~/" <> Install.shim_path(), "the hook shim every hook calls"},
      {"~/.claude/settings.json", "the three hooks"}
    ]
    |> Enum.map_join("\n", fn {path, what} ->
      "  " <> String.pad_trailing(path, 40) <> what
    end)
  end

  # ~/.claude/settings.json is commonly a link into a dotfiles repo. Every
  # write went through the link, so the change is sitting in that repo and the
  # person's next move is there, not here.
  defp through_links do
    case Install.global_links() do
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
      say(removal_report(scope, removed ++ commands, linked))
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
        Install.retired_skills() ++ base_statusline(scope)

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
        sidebar(main)

      :error ->
        IO.puts(
          :stderr,
          "whiska: #{cwd} is not a git checkout, and not inside a worktree of one."
        )

        1
    end
  end

  # The sidebar's lines, worked out now from the same board the owl writes them
  # from — what somebody runs when the sidebar looks wrong.
  defp sidebar(main) do
    socket =
      case Herdr.socket() do
        {:ok, socket} -> socket
        {:error, _} -> nil
      end

    with {:ok, handle} <- Storage.open(main) do
      try do
        board = Whiska.Watch.from_house(panes: ask_herdr(socket, :list_panes))
        no_workspace = no_workspace(board, ask_herdr(socket, :workspaces))

        house =
          Sidebar.house(board, main_pane?: Storage.main_pane() != nil, no_workspace: no_workspace)

        case Sidebar.render(house, Sidebar.mice(board)) do
          "" -> say("Nothing on the sidebar: no mouse here, and nothing about the repo to say.")
          lines -> say(lines)
        end
      after
        Storage.close(handle)
      end
    else
      {:error, reason} ->
        IO.puts(:stderr, "whiska: could not reach this repo's house (#{inspect(reason)}).")
        1
    end
  end

  defp ask_herdr(nil, _call), do: :no_socket
  defp ask_herdr(socket, call), do: apply(Herdr.impl(), call, [socket])

  # With no word from herdr about its workspaces, every mouse is taken to have
  # one: a count that cannot be checked is not said.
  defp no_workspace(board, {:ok, workspaces}) do
    placed = Sidebar.place(board, workspaces)

    for row <- board.rows,
        not Map.has_key?(placed, row.mouse_id),
        into: MapSet.new(),
        do: row.mouse_id
  end

  defp no_workspace(_board, _no_answer), do: MapSet.new()

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

  # Plain: a mouse reads this as the branch to diff against.
  defp show_base(mouse_id, layout) do
    recorded = with %Mouse{base: base} <- Storage.mouse(mouse_id), do: base

    case Git.base_of(layout.main_checkout, recorded) do
      {:ok, base} ->
        say(base)

      {:error, reason} ->
        IO.puts(:stderr, "whiska: no base branch to compare with (#{describe(reason)}).")
        1
    end
  end

  # A mode is the deny list Claude starts with (ADR-next-a-mouse-starts-in-bypass-mode),
  # which a running session cannot take.
  defp refuse_mode(mouse_id, layout, mode) do
    case Storage.mouse(mouse_id) do
      %Mouse{shaped_at: %DateTime{}} = mouse ->
        keeps_its_mode(layout, mouse)

      _never_shaped ->
        IO.puts(
          :stderr,
          "whiska: #{layout.branch_label} was never shaped, and a mode reaches Claude only " <>
            "as its launch flags. Run `whiska shape #{mode}` in this worktree, then restart " <>
            "Claude there with the flags it prints."
        )

        1
    end
  end

  defp keeps_its_mode(layout, mouse) do
    had =
      if mouse.shaped_as,
        do: "was shaped as #{mouse.shaped_as}",
        else: "already has its mode (#{mouse.mode})"

    IO.puts(
      :stderr,
      "whiska: #{layout.branch_label} #{had}, and a mouse keeps its mode (ADR-0074). " <>
        "Its model and effort were chosen for that work. To build what it found, end " <>
        "its report on What to change and have a fresh mouse shaped for the build."
    )

    1
  end

  # stdout is the flags to start Claude with — plain words only, or nothing —
  # so a spawn by hand can split them straight into `claude`'s arguments; what
  # was recorded goes to stderr, for the person.
  # Another mode would flip the mouse in place (ADR-0074), a sniff mouse to
  # build by its own hand among them.
  defp shape(mouse_id, layout, %{mode: wanted} = shape) do
    case Storage.mouse(mouse_id) do
      %Mouse{shaped_at: %DateTime{}, mode: mode} = mouse when mode != wanted ->
        keeps_its_mode(layout, mouse)

      _ ->
        case Whiska.Spawn.shape(mouse_id, layout, shape, nil) do
          {:ok, %{flags: flags, said: said}} ->
            Enum.each(said, &IO.puts(:stderr, &1))
            say(Enum.join(flags, " "))

          {:error, reason} ->
            IO.puts(:stderr, "whiska: could not shape this mouse (#{inspect(reason)}).")
            1
        end
    end
  end

  defp spawn(cwd, args) do
    case Whiska.Spawn.parse(args) do
      {:ok, request} -> with_herdr(cwd, "spawn a mouse in", &Whiska.Spawn.run(&1, request, &2))
      {:error, message} -> fail("whiska: #{message}")
    end
  end

  defp land(%Question{} = q, cwd, commit) do
    {:ok, main} = main_checkout(cwd || File.cwd!())

    with %Mouse{} = mouse <- Storage.mouse(q.mouse_id),
         {:ok, report} <- Whiska.Land.run(main, mouse, commit) do
      say(report)
    else
      nil -> fail("whiska: ##{q.id} has no mouse, so no branch to land.")
      {:error, message} -> fail("whiska: #{message}")
    end
  end

  defp pr(%Question{} = q, cwd, commit) do
    {:ok, main} = main_checkout(cwd || File.cwd!())

    with %Mouse{} = mouse <- Storage.mouse(q.mouse_id),
         {:ok, report} <- Whiska.PR.run(main, mouse, q, commit) do
      say(report)
    else
      nil -> fail("whiska: ##{q.id} has no mouse, so no branch to open a merge request for.")
      {:error, message} -> fail("whiska: #{message}")
    end
  end

  # Run `work` with this repo's main checkout and herdr, in an open house, and
  # print what it answers.
  defp with_herdr(cwd, cannot, work) do
    with_house(cwd, fn ->
      {:ok, main} = main_checkout(cwd || File.cwd!())

      case herdr_socket() do
        {:ok, socket} ->
          case work.(main, %{herdr: Herdr.impl(), socket: socket}) do
            {:ok, report} -> say(report)
            {:error, message} -> fail("whiska: #{message}")
          end

        {:error, {:no_socket, default}} ->
          no_socket(default, cannot)
      end
    end)
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
            start_claude(main, pane, claude?)

          nil ->
            record_main(main, pane)
            start_claude(main, pane, claude?)

          other ->
            if force? or not running_claude?(other) do
              record_main(main, pane)
              start_claude(main, pane, claude?)
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
  # starts one, with the main session's brief, rather than leaving the person a
  # second command to remember.
  #
  # The pane is recorded first because this is the last thing that happens
  # here — whiska is itself what is running in that pane, and starting Claude
  # means handing the pane over and getting out of the way. The line is typed
  # at the shell prompt and waits there until this process exits.
  defp start_claude(main, pane, claude?) do
    case Whiska.Brief.write_main(main) do
      {:ok, brief} ->
        cond do
          running_claude?(pane) -> briefed(pane, brief)
          not claude? -> say("Nothing is delivered until Claude Code is running in this pane.")
          true -> run_claude(pane, brief)
        end

      {:error, reason} ->
        fail("whiska: could not write the main session's brief (#{inspect(reason)}).")
    end
  end

  defp claude_line(brief), do: "claude --append-system-prompt-file " <> shell_quote(brief)

  defp shell_quote(text), do: "'" <> String.replace(text, "'", ~S('\'')) <> "'"

  # A Claude started some other way never read the brief, so it does not know
  # it is Whiska or which commands are the person's. Only a restart reads it.
  defp briefed(pane, brief) do
    with {:ok, socket} <- Herdr.socket(),
         {:ok, processes} <- Herdr.impl().processes(socket, pane),
         false <- Whiska.Brief.started_with?(processes, brief) do
      say("""
      Claude Code is running here without Whiska's brief, so it does not know it is
      Whiska or which commands are yours. Quit it and restart it with:

        #{claude_line(brief)}
      """)
    else
      _ -> 0
    end
  end

  # With no herdr to ask, neither half of this is knowable: whether Claude is
  # already running in the pane, and whether it could be started. The pane is
  # recorded either way, and saying so is the whole of what is left to do —
  # not a failure, because nothing was attempted and failed.
  defp run_claude(pane, brief) do
    case Herdr.socket() do
      {:ok, socket} ->
        case Herdr.impl().run_command(socket, pane, claude_line(brief)) do
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
            say(render(summary, shape, main))

          {:error, reason} ->
            fail("whiska: could not open this repo's house (#{inspect(reason)}).")
        end

      :error ->
        fail("whiska: #{cwd} is not a git checkout, and not inside a worktree of one.")
    end
  end

  defp render(summary, :listing, _main), do: Questions.render(summary)

  defp render(summary, :full, main),
    do:
      Questions.render_full(
        summary,
        &on_branch(main, &1),
        &research(main, &1),
        &documents(main, &1)
      )

  # Not repo-scoped: the line is machine-wide and herdr draws one of them for
  # the whole session (ADR-0048). Always 0 and never noisy — this runs every
  # few seconds, and herdr clears the entry on a non-zero exit.
  defp statusline do
    IO.puts(Whiska.Statusline.render(Whiska.Statusline.summary()))
    0
  end

  # What a statusline script an older `whiska init` committed runs on a timer.
  # The mice's state is herdr's sidebar's now, so it prints nothing and that
  # script draws only the person's own line until `whiska init` takes it out.
  defp statusline_here, do: 0

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

  # -- where ---------------------------------------------------------------------

  # A stable interface for scripts outside Whiska, so the keys go out in a fixed
  # order and every one is always there. Exits 0 everywhere: "not a worktree" is
  # an answer, not a failure, and so is anything that goes wrong on the way —
  # it becomes a null, never a crash a hook would have to survive. The worktree
  # comes from the layout alone (ADR-0030); only the main checkout, which the
  # layout cannot see from inside itself, is git's to say.
  @where_version 1

  # A hook calls this on every tool use, so a herdr that hangs must not hang it.
  @where_herdr_deadline_ms 500

  defp where_am_i(cwd) do
    {worktree, branch, main} = place(Layout.canonical(cwd))

    [
      version: @where_version,
      worktree: worktree,
      branch: branch,
      main_checkout: main,
      main_workspace: main && main_workspace(main)
    ]
    |> Enum.map_join(",", fn {key, value} -> ~s("#{key}":) <> JSON.encode!(text_or_nil(value)) end)
    |> then(&IO.puts("{" <> &1 <> "}"))

    0
  end

  defp place(cwd) do
    case Layout.resolve(cwd) do
      {:ok, layout} ->
        {layout.worktree_root, layout.branch_label, layout.main_checkout}

      {:error, :not_in_worktree} ->
        case Git.main_checkout(cwd) do
          {:ok, main} -> {nil, nil, main}
          {:error, _} -> {nil, nil, nil}
        end
    end
  rescue
    # No git on this machine.
    _ in ErlangError -> {nil, nil, nil}
  end

  # A path that is not UTF-8 — possible on Linux — has no JSON string, so it
  # is null rather than an encoder crash.
  defp text_or_nil(value) when is_binary(value), do: if(String.valid?(value), do: value)
  defp text_or_nil(value), do: value

  # In a process of its own, so a herdr that never answers costs the deadline
  # and nothing more, and a reply that makes the lookup raise is a null.
  # `$callers` lets a test's herdr fake follow the call into it.
  defp main_workspace(main) do
    parent = self()
    ref = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        Process.put(:"$callers", [parent])
        send(parent, {ref, herdr_main_workspace(main)})
      end)

    receive do
      {^ref, id} ->
        Process.demonitor(monitor, [:flush])
        text_or_nil(id)

      {:DOWN, ^monitor, :process, _, _} ->
        nil
    after
      @where_herdr_deadline_ms ->
        Process.exit(pid, :kill)
        Process.demonitor(monitor, [:flush])
        nil
    end
  end

  # Caught here rather than left to crash the process, which would print a
  # crash report on stderr; the JSON is the whole answer.
  defp herdr_main_workspace(main) do
    with {:ok, socket} <- herdr_socket(),
         {:ok, id} when is_binary(id) <- Herdr.impl().main_workspace(socket, main) do
      id
    else
      _ -> nil
    end
  catch
    _kind, _reason -> nil
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
  # on spec, and exiting 1 would make a hotkey script look broken. So is a
  # house with no main session recorded: something to run `whiska start` in,
  # not something that failed.
  defp jump_to_oldest do
    case Waiting.list() do
      [] -> say("🦉 Nothing needs you · the owl delivers when something does")
      [oldest | _] -> jump_to_house(oldest.main_checkout)
    end
  end

  # Printed bare, not through `say/1`: an empty record is an empty list, and a
  # script reading it wants no trailing blank line.
  defp jump_list(format) do
    IO.write(format.(Waiting.whiskas()))
    0
  end

  defp jump_to_name(name) do
    case Waiting.house_for(name) do
      {:ok, main} ->
        jump_to_house(main)

      {:error, :no_such_target} ->
        fail(
          "whiska: no recorded house is called #{name}, and none has a live mouse on " <>
            "a branch of that name. `whiska inbox` lists what is waiting anywhere."
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

  # `whiska open` takes the person to a mouse's own pane — the separate move
  # ADR-0043 allows, which `jump` never makes. The pane is
  # found by its folder inside the worktree, not by the stored pane column
  # (ADR-0061). What it says when there is no pane depends on what is left of
  # the mouse; none of those is a failure, so all exit 0.
  defp open_mouse(cwd, target) do
    with_house(cwd, fn ->
      case open_target(target) do
        {:ok, branch, path} ->
          {:ok, main} = main_checkout(cwd || File.cwd!())
          open_work(main, branch, path)

        :error ->
          fail("whiska: no question #{target}, and no mouse on a branch called #{target}, here.")
      end
    end)
  end

  defp open_target(target) do
    mouse =
      case Integer.parse(target) do
        {n, ""} ->
          with %Question{mouse_id: id} <- Storage.question(n), do: Storage.mouse(id)

        _branch ->
          Enum.find(Enum.reverse(Storage.current_mice()), &(&1.branch == target))
      end

    case mouse do
      %Mouse{branch: branch, path: path} when is_binary(branch) and is_binary(path) ->
        {:ok, branch, path}

      _none ->
        :error
    end
  end

  defp open_work(main, branch, path) do
    case herdr_socket() do
      {:ok, socket} ->
        with {:ok, panes} <- Herdr.impl().list_panes(socket) do
          here = Enum.filter(panes, &(is_binary(&1[:cwd]) and Layout.inside?(&1.cwd, path)))

          case Enum.find(here, &(&1[:agent] == "claude")) || List.first(here) do
            %{pane_id: pane} -> focus_mouse(socket, pane, branch)
            nil -> open_without_pane(main, socket, branch, path)
          end
        else
          {:error, reason} ->
            fail("whiska: could not ask herdr for panes (#{describe(reason)}). Nothing moved.")
        end

      {:error, {:no_socket, default}} ->
        no_socket(default, "open a mouse in")
    end
  end

  defp focus_mouse(socket, pane, branch) do
    case Herdr.impl().focus(socket, pane) do
      :ok ->
        say("Opened #{branch} — pane #{pane}.")

      {:error, reason} ->
        fail("whiska: could not focus #{pane} (#{describe(reason)}). Nothing moved.")
    end
  end

  defp open_without_pane(main, socket, branch, path) do
    cond do
      File.dir?(path) ->
        case Herdr.impl().open_worktree(socket, path) do
          :ok ->
            say("Opened #{branch}'s worktree in herdr — no session is running there.")

          {:error, reason} ->
            fail("whiska: could not open #{path} (#{describe(reason)}). Nothing moved.")
        end

      match?({:ok, _}, Git.branch_head(main, branch)) ->
        kept(main, branch)

      true ->
        say("whiska: #{branch} has no worktree and no branch — it landed or was dropped.")
    end
  end

  defp recorded_base(branch) do
    # Every record, a removed one included: the branch outliving its worktree
    # is what brings us here, and its base is still the one it was cut from.
    Mouse
    |> Storage.all()
    |> Enum.filter(&(&1.branch == branch and &1.base))
    |> Enum.max_by(& &1.created_at, DateTime, fn -> nil end)
    |> case do
      %Mouse{base: base} -> base
      nil -> nil
    end
  end

  defp kept(main, branch) do
    commits =
      case Git.ahead(main, branch, recorded_base(branch)) do
        {:ok, 1} -> "1 commit beyond the base"
        {:ok, n} -> "#{n} commits beyond the base"
        {:error, _} -> "an unknown number of commits"
      end

    say(
      "whiska: #{branch}'s worktree is gone but the branch is kept, with #{commits}. " <>
        "Spawn it again to work on it."
    )
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

  # Only what has reached the person: a queued question waits its turn, and
  # `inbox` is where the rest of the queue is read (ADR-0008, ADR-0079).
  defp show_delivered(cwd) do
    case Mode.delivered(Storage.questions(), Mode.read()) do
      nil -> say("Nothing is delivered to you right now. `inbox` lists what is waiting.")
      q -> show_question(q, cwd)
    end
  end

  # The shape lives in Whiska.Questions, so one question read by id and one
  # block of `whiska questions --full` cannot drift apart. This question was
  # loaded by id, without its mouse, so the mouse is looked up here.
  defp show_question(%Question{} = q, cwd) do
    cwd = cwd || File.cwd!()
    {:ok, main} = main_checkout(cwd)
    mode = Mode.read()
    slot = Mode.slot(Storage.questions(), mode)
    focus = if mode.focus, do: Questions.who(Storage.mouse(mode.focus), mode.focus)
    who = Questions.who(Storage.mouse(q.mouse_id), q.mouse_id)

    say(
      Questions.full(
        q,
        who,
        slot,
        mode,
        focus,
        &on_branch(main, &1),
        &research(main, &1),
        &documents(main, &1)
      )
    )
  end

  defp research(main, %Question{} = q), do: Whiska.Research.find(main, q, mouse_of(q))

  defp documents(main, %Question{} = q) do
    mouse = mouse_of(q)
    ahead_of_build(q, mouse) ++ report(main, mouse)
  end

  # The spec and build plan are what the person is asked to review before the
  # build, so only a question still open on them links them; a finished
  # report's own link is the one to read.
  defp ahead_of_build(%Question{kind: "done"}, _mouse), do: []
  defp ahead_of_build(_question, mouse), do: in_worktree(mouse)

  # The spec and build plan a mouse asks the person to review, linked where
  # they stand in its worktree (ADR-0063). A viewer the person names in
  # WHISKA_SPEC_LINK takes each; otherwise the file link annotate opens
  # (ADR-0085).
  defp in_worktree(%Mouse{path: path, branch: branch})
       when is_binary(path) and is_binary(branch) do
    for {label, name} <- [
          {"Spec", Whiska.Spec.filename()},
          {"Build plan", Whiska.BuildPlan.filename()}
        ],
        {file, title} <- [Whiska.Research.document(Path.join(path, name), nil)],
        do: {label, document_link(file, branch), title}
  end

  defp in_worktree(_mouse), do: []

  # Whiska's own copy, linked like the research document, so it opens after the
  # worktree is gone (ADR-0089).
  defp report(main, %Mouse{mouse_id: mouse_id, branch: branch}) when is_binary(branch) do
    with file when is_binary(file) <- Whiska.SpecArchive.report(main, mouse_id, branch),
         {file, title} <- Whiska.Research.document(file, nil) do
      [{"Full report", Review.file_link(file), title}]
    else
      _ -> []
    end
  end

  defp report(_main, _mouse), do: []

  defp document_link(file, branch) do
    case Review.spec_link(System.get_env("WHISKA_SPEC_LINK"), file, branch) do
      {:ok, link} -> link
      :error -> Review.file_link(file)
    end
  end

  defp mouse_of(%Question{mouse: %Mouse{} = mouse}), do: mouse
  defp mouse_of(%Question{mouse: nil}), do: nil
  defp mouse_of(%Question{mouse_id: mouse_id}), do: Storage.mouse(mouse_id)

  # A question read by id comes without its mouse, and one from the listing
  # with it — the house is already closed by the time the listing renders.
  defp on_branch(main, %Question{} = q), do: held(main, mouse_of(q))

  # The diff file is written wherever the show runs: a main session whose
  # shell sits in a mouse's worktree reads a finished branch too, and the
  # file is Whiska's own, ignored like the kept specs (ADR-0085).
  defp held(main, %Mouse{path: path, branch: branch, base: base} = mouse)
       when is_binary(path) and is_binary(branch) do
    with {:ok, held} <- Git.on_branch(main, path, branch, base),
         {:ok, held} <- merge_request(main, held, mouse) do
      {:ok, Map.merge(held, review(main, branch, base, held))}
    end
  end

  defp held(_main, _no_worktree), do: {:error, :no_record}

  defp merge_request(main, held, %Mouse{merge_request_url: url} = mouse) do
    if is_binary(url) and Mouse.merge_request_waiting?(mouse) do
      with {:ok, n} <- Git.not_pushed(main, mouse.branch, mouse.base),
           do: {:ok, Map.merge(held, %{merge_request: url, not_pushed: n})}
    else
      {:ok, held}
    end
  end

  # A diff viewer the person names in WHISKA_DIFF_LINK takes the link, and
  # no file is written (ADR-0085). The heading stands without the diff
  # link when the file cannot be written.
  defp review(_main, _branch, _base, %{ahead: 0}), do: %{}

  defp review(main, branch, base, held) do
    case Review.link(System.get_env("WHISKA_DIFF_LINK"), held.base_ref, branch) do
      {:ok, link} -> %{review: link}
      :error -> review_file(main, branch, base, held.ahead)
    end
  end

  defp review_file(main, branch, base, ahead) do
    with {:ok, %{base: base_name, diff: diff}} <- Git.branch_diff(main, branch, base),
         {:ok, path} <- Review.write(main, base_name, branch, ahead, diff) do
      %{review: Review.file_link(path)}
    else
      _ -> %{}
    end
  end

  # -- away, focus, hold and resume (ADR-0079)

  defp inbox(shape, scope, cwd) do
    entries = inbox_entries(scope, cwd)

    case shape do
      :json -> say(Waiting.json(entries))
      :text -> say(Waiting.render(entries, away?: Mode.away?()))
    end
  end

  defp inbox_entries(:here, cwd) do
    case main_checkout(cwd || File.cwd!()) do
      {:ok, main} -> Waiting.house(main)
      :error -> Waiting.list()
    end
  end

  defp inbox_entries(:all, _cwd), do: Waiting.list()

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
  # finished line is what the person hears next, once nothing is out waiting
  # on them (ADR-0008). Anything older was there before
  # the hold and is the person's to answer.
  defp carry_on(mouse, branch, held_at, %Question{asked_at: asked_at} = latest)
       when is_struct(asked_at, DateTime) do
    cond do
      DateTime.compare(asked_at, held_at) == :gt and latest.kind == "done" ->
        say(
          "Hold on #{branch} lifted. It had finished; its finished line is told " <>
            "once nothing else is out waiting on you."
        )

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
      now = DateTime.utc_now()

      # Whiska's own line, typed straight into the pane: taken as it is
      # answered, so the owl never rings for it as though the person had
      # (ADR-0080).
      if stop.status in ["open", "sent"] do
        Storage.answer(stop.id, Mode.resume_line(), stamp: false)
        Storage.take([stop.id], now)
      end

      Storage.set_working(mouse.mouse_id, now)
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

  # Saved before anything is typed, and only the doorbell is typed: the answer
  # reaches the mouse through its own hook, which stamps it taken
  # (ADR-0080). Once saved the answer is safe, so a
  # doorbell that does not ring is the owl's to ring again, not a failed reply.
  defp reply(%Question{} = q, text) do
    with {:ok, mouse} <- live_mouse(q),
         {:ok, _} <- Storage.answer(q.id, text) do
      notes = [lift_hold_for_answer(mouse), flag(mouse)]
      say(rang(q, mouse, ring(q, mouse)) <> Enum.join(Enum.reject(notes, &is_nil/1)))
    else
      {:error, {:dead, mouse}} ->
        dead_mouse(q, mouse)

      {:error, reason} ->
        fail("whiska: could not save the answer (#{describe(reason)}). ##{q.id} is unchanged.")
    end
  end

  # herdr's client can exit rather than answer — `gen_tcp` exits `badarg` on
  # some socket paths — and by now the answer is saved, so that is one more
  # doorbell for the owl to ring, never a crash.
  defp ring(q, mouse) do
    with {:ok, socket} <- herdr_socket(),
         :ok <- Doorbell.press(Herdr.impl(), socket, mouse.pane, q.id) do
      Storage.rung(q.id, DateTime.utc_now())
      :ok
    end
  end

  defp rang(q, mouse, :ok),
    do: "Answered ##{q.id} (#{mouse.branch}): saved, and rang its doorbell in #{mouse.pane}."

  defp rang(q, mouse, {:error, reason}) do
    "Answered ##{q.id} (#{mouse.branch}): saved, but its doorbell did not ring " <>
      "(#{unrung(reason)}). The owl will ring it."
  end

  defp unrung({:no_socket, default}), do: "no herdr socket at #{default}"
  defp unrung(reason), do: describe(reason)

  # Answering a held mouse is picking it up: a hold left in place would have the
  # hook refuse the very turn the answer starts.
  defp lift_hold_for_answer(%Mouse{held_at: %DateTime{}} = mouse) do
    case Storage.lift_hold(mouse.mouse_id) do
      {:ok, _} ->
        " The hold on #{mouse.branch} is lifted."

      {:error, reason} ->
        " The hold on #{mouse.branch} could not be lifted (#{describe(reason)}); " <>
          "`resume #{mouse.branch}` lifts it."
    end
  end

  defp lift_hold_for_answer(_mouse), do: nil

  defp flag(mouse) do
    case AnswerFlag.set(mouse.path) do
      :ok ->
        nil

      {:error, reason} ->
        " Could not mark its worktree (#{describe(reason)}); the owl marks it again before it rings."
    end
  end

  defp dead_mouse(q, mouse) do
    fail("""
    whiska: ##{q.id}'s mouse (#{mouse.branch}) is dead — its pane is gone.

    The worktree is still on disk at #{mouse.path}. `whiska reopen` is not
    built yet; start Claude Code there by hand and pass the answer on
    yourself, then `whiska dismiss #{q.id}`.
    """)
  end

  defp close(%Question{} = q) do
    case Storage.close_question(q.id) do
      {:ok, _} -> say("Closed ##{q.id} without an answer.")
      {:error, :not_answerable} -> fail("whiska: ##{q.id} is already #{q.status}.")
      {:error, reason} -> fail("whiska: could not close ##{q.id} (#{inspect(reason)}).")
    end
  end

  # The link is printed under the heading, where the main session reads
  # it, so it is a plain https one or nothing.
  defp record_merge_request(%Question{} = q, url) do
    with true <- Whiska.PR.link?(url) || :not_a_link,
         %Mouse{branch: branch} <- Storage.mouse(q.mouse_id) || :no_mouse,
         {:ok, _} <- Storage.record_merge_request(q.mouse_id, url) do
      say("Recorded: #{branch}'s merge request, #{url}.")
    else
      :not_a_link ->
        fail("whiska: #{inspect(url)} is not a plain https link. Nothing recorded.")

      :no_mouse ->
        fail("whiska: ##{q.id} has no mouse to record a merge request on.")

      {:error, reason} ->
        fail("whiska: could not record the merge request (#{inspect(reason)}).")
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

  defp describe({:base_gone, name}), do: "its base branch #{name} is gone"
  defp describe(:unsafe_base), do: "its base branch's name is not a plain one"

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
        fail("whiska: #{id} is not a question id — expected a number, as `whiska show` shows.")
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
  # launchd on macOS, systemd on Linux (ADR-0040);
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
      The argument after the script is the key you bound to reach what waits,
      shown on the line when something does; change it to yours, or drop it.
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
