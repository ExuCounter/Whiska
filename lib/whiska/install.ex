defmodule Whiska.Install do
  @moduledoc """
  Writing Whiska's hook into a repo's own `.claude/settings.json`.

  ADR-0016 makes hooks per-project rather than global, and the file is checked
  into git so the rules travel with the repo: anyone who clones it and has Whiska
  installed gets the same enforcement automatically. Global hooks would mean zero
  setup per project but would not travel, which is the wrong trade for rules that
  exist to contain what a worker can do.

  ## Nothing machine-specific reaches settings.json

  "The rules travel with the repo" is only true if what gets committed works on
  somebody else's machine. An earlier version wrote two absolute paths into the
  hook command — the Erlang runtime and the binary, both resolved at install
  time — which pinned the file to one home directory and one Erlang version, and
  leaked a username into a shared repo besides. It also broke as soon as the
  runtime was upgraded.

  So the committed command names only a **shim** checked in beside it, and every
  machine-specific lookup moved into that shim, where it happens at run time.
  `WHISKA_BIN` and `WHISKA_ESCRIPT` override the lookups without editing it.

  The shim costs one extra process — about 5 ms. That was rejected when this was
  written, on the grounds that a shell wrapper costs more than ADR-0033's
  eventual native hook will cost in total. True, but the hook that exists today
  is an Elixir escript measured at ~124 ms per call, so the wrapper is about 4%
  of it. The cost lands on the version of the hook that can afford it, and the
  indirection means `settings.json` never has to change again when ADR-0033's
  native binary replaces what the shim points at.

  Everything here is a pure value except the actual write, so the merge behaviour
  — idempotency, leaving other people's hooks alone — is testable without
  touching a filesystem.
  """

  # Every tool that a rule can actually deny, and no others.
  #
  # `Bash` earns its place: sniff mode denies mutating commands (ADR-0018) and
  # containment denies ones reaching into the main checkout (ADR-0013), so a
  # matcher without it would leave both rules silently never firing.
  #
  # `Read`, `Grep` and `Glob` are deliberately absent. They are a large share of
  # all tool calls and can never be denied, and ADR-0033 is blunt about it: not
  # running at all beats running fast.
  @matcher "Write|Edit|MultiEdit|NotebookEdit|Bash"

  @shim_path ".claude/hooks/whiska.sh"

  # The two roots the same relative paths hang off (ADR-0056): the repo, and the
  # person's own home. `.claude/hooks/whiska.sh` is one file in two places.
  @type scope :: :repo | :global

  # The shim takes the hook's name as its argument, so one committed script
  # serves every hook Whiska registers.
  @command ~s|bash "$CLAUDE_PROJECT_DIR/#{@shim_path}" pre-tool-use|
  @stop_command ~s|bash "$CLAUDE_PROJECT_DIR/#{@shim_path}" stop|
  @prompt_command ~s|bash "$CLAUDE_PROJECT_DIR/#{@shim_path}" user-prompt-submit|
  @session_start_command ~s|bash "$CLAUDE_PROJECT_DIR/#{@shim_path}" session-start|

  @global_command ~s|bash "$HOME/#{@shim_path}" pre-tool-use|
  @global_stop_command ~s|bash "$HOME/#{@shim_path}" stop|
  @global_prompt_command ~s|bash "$HOME/#{@shim_path}" user-prompt-submit|
  @global_session_start_command ~s|bash "$HOME/#{@shim_path}" session-start|

  @shim_header """
  #!/usr/bin/env bash
  # Whiska's hooks. Takes the hook's name - pre-tool-use, stop or
  # user-prompt-submit - and hands the payload on stdin to `whiska hook <name>`.
  #
  # Written by `whiska init` and checked into the repo so the rules travel with
  # it (ADR-0016). Everything machine-specific is resolved here, when the hook
  # runs, rather than baked into .claude/settings.json where it would name one
  # developer's home directory and one Erlang version.
  #
  # A hook does not necessarily inherit an interactive shell's PATH, so every
  # lookup ends by searching the filesystem directly rather than trusting it.
  # WHISKA_BIN and WHISKA_ESCRIPT override either, and are ignored if they do
  # not point at something runnable.

  """

  # Every prompt in every session runs the user-prompt-submit hook, and almost
  # none has an answer waiting, so that case leaves here before the binary or
  # the runtime is looked for (ADR-0080). Shell
  # builtins only: the worktree's `.git` file names its git admin directory,
  # and the answer flag sits there. With no project directory to decide on,
  # Whiska decides - an answer not handed over is worse than a prompt slowed.
  @prompt_fast_path """
  if [ "${1:-}" = "user-prompt-submit" ] && [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
    case "$CLAUDE_PROJECT_DIR" in
      */worktrees/*) ;;
      *) exit 0 ;;
    esac
    [ -f "$CLAUDE_PROJECT_DIR/.git" ] || exit 0
    whiska_gitdir=""
    IFS= read -r whiska_gitdir < "$CLAUDE_PROJECT_DIR/.git" || [ -n "$whiska_gitdir" ] || exit 0
    whiska_gitdir="${whiska_gitdir#gitdir: }"
    case "$whiska_gitdir" in
      /*) ;;
      *) whiska_gitdir="$CLAUDE_PROJECT_DIR/$whiska_gitdir" ;;
    esac
    [ -e "$whiska_gitdir/whiska-answer" ] || exit 0
  fi

  """

  # Finding the binary and the runtime is written once and shared with both
  # status scripts below, so they never drift apart.
  @resolve_whiska """
  whiska_bin="${WHISKA_BIN:-}"
  if [ -n "$whiska_bin" ] && [ ! -x "$whiska_bin" ]; then
    whiska_bin=""
  fi
  if [ -z "$whiska_bin" ]; then
    whiska_bin="$(command -v whiska 2>/dev/null)" || whiska_bin=""
  fi
  if [ -z "$whiska_bin" ] && [ -x "$HOME/.local/bin/whiska" ]; then
    whiska_bin="$HOME/.local/bin/whiska"
  fi

  """

  @shim_fail_open """
  # Fail open, loudly. A missing Whiska must never brick every tool call in a
  # session - the same trade Whiska.Hook.PreToolUse makes on a bad payload, and
  # the one it makes again when it cannot read a mouse's mode. The shim cannot
  # read the mode either, so it cannot deny only a sniff mouse.
  #
  # Loud means exit 1. Claude Code files an exit-0 hook's stderr as a success
  # and never shows it; exit 1 is shown as a hook error and still lets the call
  # through, and a Stop hook exiting 1 ends the turn without looping. Exit 2
  # would deny every edit, and make a Stop hook keep the turn going.
  #
  # Only where it costs something: a session in a worktree, where a mouse can
  # be, in a repo Whiska is set up in on this machine - its house exists, or
  # the binary was found. A committed hook on a machine without Whiska, or a
  # session outside a worktree, where every hook is a no-op, stays exit 0. The
  # complaint goes to stderr either way, which is what the doctor's probe reads.
  whiska_cannot_run() {
    local project="${CLAUDE_PROJECT_DIR:-$PWD}" common
    echo "whiska: $1" >&2
    case "$project" in
      */worktrees/*) ;;
      *) exit 0 ;;
    esac
    if [ -z "$whiska_bin" ]; then
      # bash 3.2's `cd ""` succeeds and stays put, so git's answer is checked
      # for emptiness before anything changes directory to it.
      common="$(cd "$project" 2>/dev/null && git rev-parse --git-common-dir 2>/dev/null)" ||
        common=""
      if [ -n "$common" ]; then
        common="$(cd "$project" && cd "$common" 2>/dev/null && pwd)" || common=""
      fi
      if [ -z "$common" ] || [ ! -d "$common/whiska" ]; then
        exit 0
      fi
    fi
    if [ "${2:-}" = "stop" ]; then
      echo "whiska: this turn's message was not delivered - run whiska doctor" >&2
    elif [ "${2:-}" = "user-prompt-submit" ]; then
      echo "whiska: the answer waiting here was not handed over - run whiska doctor" >&2
    elif [ "${2:-}" = "session-start" ]; then
      echo "whiska: this session started without Whiska's rules - run whiska doctor" >&2
    else
      echo "whiska: sniff mode and worktree containment are off - run whiska doctor" >&2
    fi
    exit 1
  }

  if [ -z "$whiska_bin" ]; then
    whiska_cannot_run "not found - allowing the call (set WHISKA_BIN to fix)" "${1:-}"
  fi

  """

  @resolve_escript """
  # An escript begins `#!/usr/bin/env escript`, so it only runs when escript is
  # on PATH. With a version manager in play it is not found at all - and asking
  # the version manager does not help when it is off PATH too, which is exactly
  # the case a hook lands in. So the last resort reads its install directory.
  escript_bin="${WHISKA_ESCRIPT:-}"
  if [ -n "$escript_bin" ] && [ ! -x "$escript_bin" ]; then
    escript_bin=""
  fi
  if [ -z "$escript_bin" ]; then
    escript_bin="$(command -v escript 2>/dev/null)" || escript_bin=""
  fi
  if [ -z "$escript_bin" ] && command -v asdf >/dev/null 2>&1; then
    escript_bin="$(asdf which escript 2>/dev/null)" || escript_bin=""
  fi
  if [ -z "$escript_bin" ]; then
    escript_bin="$(ls -1 "${ASDF_DATA_DIR:-$HOME/.asdf}"/installs/erlang/*/bin/escript \
      2>/dev/null | sort -V | tail -1)"
  fi
  if [ -z "$escript_bin" ]; then
    for candidate in /opt/homebrew/bin/escript /usr/local/bin/escript /home/linuxbrew/.linuxbrew/bin/escript; do
      if [ -x "$candidate" ]; then
        escript_bin="$candidate"
        break
      fi
    done
  fi

  """

  @shim_exec """
  if [ -n "$escript_bin" ]; then
    # Not `exit 0`: exec carries the hook's status out, and the doctor reads it
    # to tell a working hook from a binary that does not know it.
    exec "$escript_bin" "$whiska_bin" hook "$@"
  fi

  # No runtime anywhere. Whiska may be a native binary that needs none
  # (ADR-0033), so try it directly - and fail open, loudly, if that does not work.
  if ! "$whiska_bin" hook "$@"; then
    whiska_cannot_run "could not run $whiska_bin - allowing the call" "${1:-}"
  fi
  exit 0
  """

  @shim @shim_header <>
          @prompt_fast_path <>
          @resolve_whiska <>
          @shim_fail_open <>
          @resolve_escript <>
          @shim_exec

  # The one thing the global copy does that the committed one does not
  # (ADR-0056). Claude Code merges the hook arrays from `~/.claude` and the
  # project, so in a repo carrying its own install both would fire: two denials
  # for one tool call, and two entries on the doorstep for one finished turn.
  # The repo's own install wins and this copy stands down, before it has
  # resolved anything.
  #
  # It reads the repo's settings rather than only looking for the shim file,
  # because a shim nothing wires runs for nobody. grep rather than jq: a hook
  # cannot assume jq is installed, and nothing here needs the parse.
  # Both halves are required, and that is the security of it: a repo's
  # `settings.json` is text the repo ships, so a repo that merely mentions the
  # path could otherwise switch Whiska's enforcement off inside itself. A repo
  # that has the shim *and* wires it is a repo that ran `whiska init`.
  #
  # grep rather than jq: a hook cannot assume jq is installed, and nothing here
  # needs the parse. `-f` rather than `-r`: `-r` is true of a FIFO, and grep on
  # one with no writer waits for ever — on a hook that fires on every tool call.
  # Both halves of the stand-down are required, and that is the security of it:
  # a repo's `settings.json` is text the repo ships, so a repo that merely
  # mentions the path could otherwise switch Whiska's enforcement off inside
  # itself. A repo that has the shim *and* wires it is one that ran `whiska
  # init`.
  #
  # grep rather than jq: a hook cannot assume jq is installed, and nothing here
  # needs the parse. `-f` rather than `-r`: `-r` is true of a FIFO, and grep on
  # one with no writer waits for ever — on a hook that fires on every tool call.
  #
  # The second early-out is the one the global copy needs most. Outside a
  # worktree `Whiska.Hook.PreToolUse` has no mouse to apply a rule to and always
  # allows, so the ~140 ms escript says nothing — and this copy pays it in every
  # repo on the machine, on most of a working session's tool calls. It is
  # decided on `CLAUDE_PROJECT_DIR`, which is fixed for a session's whole life,
  # and skipped entirely when that is unset: the working directory follows every
  # `cd` the session runs (ADR-0053) and is not safe to decide on. `Stop` never
  # takes this path at all — a question lost is worse than a turn slowed.
  # The prompt hook's early exit comes before the stand-down, which greps the
  # repo's settings: a prompt with no answer waiting pays for neither.
  @global_header """
  #!/usr/bin/env bash
  # Whiska's hooks, the copy in ~/.claude (`whiska init --global`).

  """

  @shim_stand_down """
  # A repo that wires Whiska itself wins: Claude Code runs both this and the
  # repo's own hook, and running both would deny twice and leave two questions
  # on the doorstep for one turn.
  whiska_project="${CLAUDE_PROJECT_DIR:-$PWD}"
  whiska_project_shim="$whiska_project/#{@shim_path}"
  if [ -f "$whiska_project_shim" ]; then
    for whiska_settings in \
      "$whiska_project/.claude/settings.json" \
      "$whiska_project/.claude/settings.local.json"; do
      if [ -f "$whiska_settings" ] && grep -q '#{String.replace(@shim_path, ".", "\\.")}' "$whiska_settings" 2>/dev/null; then
        exit 0
      fi
    done
  fi

  # Only a session started inside a worktree can be a mouse, and only a mouse
  # has a rule to break.
  if [ "$1" = "pre-tool-use" ] && [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
    case "$CLAUDE_PROJECT_DIR" in
      */worktrees/*) ;;
      *) exit 0 ;;
    esac
  fi

  # Outside herdr no mouse is spawned and nothing is delivered, so a session
  # there starts with no rules - and this copy runs in every session on the
  # machine.
  if [ "$1" = "session-start" ] && [ "${HERDR_ENV:-}" != 1 ]; then
    exit 0
  fi

  """

  @global_shim @global_header <>
                 @prompt_fast_path <>
                 @shim_stand_down <>
                 @resolve_whiska <> @shim_fail_open <> @resolve_escript <> @shim_exec

  # The retired review loop (ADR-0049). Nothing writes it and nothing runs it;
  # the path survives so a settings entry an older version wrote is recognised
  # as Whiska's and dropped, and so the doctor can name a leftover file.
  @review_loop_path ".claude/hooks/review-loop.sh"

  @statusline_path ".claude/hooks/whiska-statusline.sh"

  # Claude Code does not set CLAUDE_PROJECT_DIR for the statusline command, only
  # for hooks; the command runs from the project directory, so the relative path
  # is the fallback, and the variable is honoured if a later version sets it.
  @statusline_command ~s|bash "${CLAUDE_PROJECT_DIR:-.}/#{@statusline_path}"|

  @global_statusline_command ~s|bash "$HOME/#{@statusline_path}"|

  # Where the global line Whiska displaced is kept (ADR-0056). A project
  # `statusLine` replaces the global one rather than merging with it, and so
  # does the global install's own entry — so the person's line would simply be
  # gone. It is recorded here instead, and both scripts run it first.
  @base_statusline_path ".claude/whiska-base-statusline"

  # Seconds between redraws, on top of Claude Code's own event triggers, which
  # all come from the session's own conversation (ADR-0044). The board is a
  # live picture of what every mouse is doing, so it is redrawn about as often
  # as that picture changes, and every second so a mouse's elapsed time under
  # an hour visibly ticks; the owl writes the board every second to match.
  # That is affordable only because the script starts nothing: it prints a
  # file the owl already wrote (ADR-0051), where the 0.8 core-seconds of
  # escript startup that set the old interval of 15 used to be.
  @statusline_refresh_interval 1

  # Bumped whenever the script changes, so a copy an older `whiska init` wrote
  # can be told apart from this one (ADR-0059). The person's own copy is
  # committed and shared with their team, so nothing rewrites it: the doctor
  # reads the stamp and says an upgrade is available.
  @statusline_version 4

  @statusline_script """
  #!/usr/bin/env bash
  # whiska-statusline: v#{@statusline_version}
  # Whiska's project statusline (ADR-0051): a board, one row per mouse in
  # this repo — its branch, what herdr says it is doing, and the question
  # waiting on you, else what it is working on, else what it is stuck in.
  #
  # Above the rows, and only when it is true, one line saying that this pane
  # is not where this repo's answers are delivered (ADR-0065).
  #
  # A project-level statusLine replaces the global one rather than merging
  # with it, so your global statusline runs first and the board goes under
  # it.
  #
  # Nothing here starts Whiska. The owl writes the board to a file every
  # second and this prints it, which is what makes a one-second refresh
  # affordable in every open session at once.
  #
  # Written by `whiska init`.

  input="$(cat)"

  # Reads one string field of the JSON on stdin; the value stays escaped.
  json_field() {
    sed -nE 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"(([^"\\\\]|\\\\.)*)".*/\\1/p'
  }

  json_unescape() {
    local s="$1"
    s="${s//\\\\\\\\/$'\\001'}"
    s="${s//\\\\\\"/\\"}"
    s="${s//\\\\\\//\\/}"
    printf '%s' "${s//$'\\001'/\\\\}"
  }

  global=""
  if [ -r "$HOME/.claude/settings.json" ]; then
    global="$(tr -d '\\n' < "$HOME/.claude/settings.json" \\
      | sed -nE 's/.*"statusLine"[[:space:]]*:[[:space:]]*\\{[^}]*"command"[[:space:]]*:[[:space:]]*"(([^"\\\\]|\\\\.)*)".*/\\1/p')"
    global="$(json_unescape "$global")"
  fi

  # A global statusLine that is Whiska's own is this script, or the copy in
  # ~/.claude. The line that one displaced is kept beside it, and that is the
  # one to run (ADR-0056).
  case "$global" in
    *whiska-statusline.sh*) global="" ;;
  esac
  if [ -z "$global" ] && [ -r "$HOME/#{@base_statusline_path}" ]; then
    global="$(cat "$HOME/#{@base_statusline_path}")"
  fi

  base=""
  [ -n "$global" ] && base="$(printf '%s' "$input" | bash -c "$global" 2>/dev/null)"

  [ -n "$base" ] && printf '%s\n' "$base"

  # The project directory before the current one, because the current one
  # follows every cd the session runs (Whiska ADR-0053): a session speaks for
  # the repo it started in, and a mouse that steps into the main checkout must
  # still read as a mouse.
  dir=""
  for key in project_dir current_dir cwd; do
    dir="$(json_unescape "$(printf '%s' "$input" | json_field "$key")")"
    [ -n "$dir" ] && break
  done
  [ -d "$dir" ] || dir="$PWD"

  # A mouse's own pane never draws the board: it is the person's view of
  # their mice, and a mouse has no use for its siblings' rows.
  case "$dir" in
    */worktrees/*) exit 0 ;;
  esac

  # The board is named after the main checkout, so a session sitting in a
  # subfolder walks up until it finds one.
  home="${WHISKA_HOME:-$HOME/.whiska}"
  board=""
  probe="$dir"
  while [ -n "$probe" ] && [ "$probe" != "/" ] && [ "$probe" != "." ]; do
    # LC_ALL=C so tr counts bytes: a path with a non-ASCII character in it
    # must be spelled the same here as the owl spells it.
    candidate="$home/board/$(printf '%s' "$probe" | LC_ALL=C tr -c 'A-Za-z0-9' '-')"
    if [ -f "$candidate" ]; then
      board="$candidate"
      break
    fi
    probe="$(dirname "$probe")"
  done

  [ -n "$board" ] || exit 0

  # Whose questions land here (ADR-0065). The owl writes the main session's
  # pane beside the board; this pane either is it or is not, and only the
  # second case is worth a line. No pane id in the environment means herdr is
  # not around to say, which is not the same as being the wrong pane — say
  # nothing.
  #
  # `-f` rather than `-r`, like the stand-down check above: `-r` is true of a
  # FIFO, and reading one with no writer waits for ever — here on a line
  # Claude Code redraws every second.
  notice=""
  if [ -n "${HERDR_PANE_ID:-}" ] && [ -f "$board.main" ]; then
    recorded=""
    read -r recorded < "$board.main" 2>/dev/null
    if [ -z "$recorded" ]; then
      notice='🐱 no main session here — nothing is delivered until `whiska start` records this pane'
    elif [ "$recorded" != "$HERDR_PANE_ID" ]; then
      notice='🐱 not the main session — answers go to another pane; `whiska start` moves them here'
    fi
  fi

  # Nothing to print and nothing to say: a quiet house writes an empty board,
  # which is most houses most of the time, and this is the line that keeps
  # them out of the two stat probes and the date below.
  [ -s "$board" ] || [ -n "$notice" ] || exit 0

  # BSD stat first, then GNU, and each answer is checked rather than trusted:
  # `stat -f` on GNU means --file-system and prints a paragraph.
  mtime="$(stat -f %m "$board" 2>/dev/null)"
  case "$mtime" in
    "" | *[!0-9]*) mtime="$(stat -c %Y "$board" 2>/dev/null)" ;;
  esac
  case "$mtime" in
    "" | *[!0-9]*) exit 0 ;;
  esac
  age=$(( $(date +%s) - mtime ))

  # A board nothing has refreshed is still mostly true for a little while,
  # and hiding it the moment something goes wrong is the worse failure. Past
  # a minute it stops being worth showing; herdr's tab bar says the owl is
  # down either way (ADR-0048). Ten seconds, not five: a house waiting on a
  # slow herdr — up to seven seconds — misses every write in that time without
  # the owl being down at all.

  # Only over a board the owl is currently writing: the pane beside it is the
  # owl's answer too, and a house nobody is refreshing may have recorded a new
  # main session since — telling the pane that just ran `whiska start` that it
  # is the wrong one is the one false alarm this line must not raise.
  if [ "$age" -le 10 ] && [ -n "$notice" ]; then
    printf '\\e[33m%s\\e[0m\\n' "$notice"
  fi

  [ -s "$board" ] || exit 0

  if [ "$age" -le 10 ]; then
    cat "$board"
  elif [ "$age" -le 60 ]; then
    printf '🦉 owl down · %ss stale\n' "$age"
    # Dim the whole of every row, over the colour the row already carries
    # (`Whiska.Watch.Ink`). A row ends its own dim with `[22m`, which would end
    # this one too and leave the rest of the line looking live, so each one is
    # followed by a fresh `[2m`.
    awk 'BEGIN { esc = sprintf("%c", 27); dim = esc "[2m" }
         { gsub(esc "\\\\[22m", esc "[22m" dim); print dim $0 esc "[0m" }' "$board"
  fi
  """

  @herdr_status_name "herdr-status.sh"

  # herdr runs the entry every `interval_seconds` without overlapping a previous
  # run, and one process per interval covers the whole machine — so five seconds
  # costs a fraction of what fifteen cost per idle Claude Code session. The
  # timeout is what herdr waits before clearing the entry; two seconds is well
  # clear of the escript startup the script pays for.
  @herdr_status_interval 5
  @herdr_status_timeout 2

  @herdr_status_script """
                       #!/usr/bin/env bash
                       # The line herdr's tab bar shows (ADR-0048): whether the owl is watching or
                       # down, always, and what is waiting anywhere on this machine. herdr takes
                       # the last line of output, so nothing else may be printed on stdout.
                       #
                       # Written by `whiska owl install`. The entry that runs it is the person's
                       # own herdr config; `whiska doctor` prints it. The binary and runtime are
                       # resolved the same way the hook shim resolves them, at run time.

                       """ <>
                         @resolve_whiska <>
                         @resolve_escript <>
                         """
                         # A blank line reads as "nothing configured", and the owl's state is the one
                         # thing that must always be shown (ADR-0027 addendum), so both ways of
                         # getting no line say which one happened rather than going quiet.
                         if [ -z "$whiska_bin" ]; then
                           printf '🦉 whiska missing'
                           exit 0
                         fi

                         if [ -n "$escript_bin" ]; then
                           "$escript_bin" "$whiska_bin" statusline 2>/dev/null || printf '🦉 whiska error'
                         else
                           "$whiska_bin" statusline 2>/dev/null || printf '🦉 whiska error'
                         fi
                         """

  # One slash-command skill per command (ADR-0022): a thin wrapper around the
  # fixed `whiska` call, discoverable via /help, so the model never has to
  # compose the bash itself. Paths are relative to the repo root.
  #
  # The six only the person types carry `disable-model-invocation`: their
  # slash commands work, and no session — a mouse's included — pays for their
  # descriptions in its context. `show` and `reply` stay where the main session
  # can reach them after a delivered question.
  #
  # The verbatim rule every reading skill carries. Claude Code folds a Bash
  # tool's result away from the person, so "show its output" alone was read as
  # "it is already visible" and the model summarised; and a fenced block turns
  # the mouse's markdown off.
  @verbatim """
  The person cannot see the command's output, only your reply. So your whole
  reply is that output, verbatim, as markdown: every line, in full and in its
  own words, no commentary before or after, and no fence around it — a code
  block would show the mouse's bold and backticks raw instead of rendering
  them. Then stop.
  """

  # One word each (ADR-0079): the slash
  # commands are the words the person types at a shell, and the two long-named
  # reading skills they replace are in `@retired_skills`.
  @skills [
    {".claude/skills/inbox/SKILL.md",
     """
     ---
     name: inbox
     description: What is waiting on you across every repo on this machine, oldest first.
     disable-model-invocation: true
     ---

     Run exactly this:

         whiska inbox

     #{String.trim(@verbatim)} Answering is the person's move: never reply to
     a question, guess an answer, or act on one on their behalf.

     It lists every repo, not only this one. A first line saying `away` means
     nothing is delivered anywhere until the person runs `resume`; a row's last
     word — `held`, `away`, `focus: <branch>` — says why that one is not being
     delivered. `/show <id>` reads one of this repo's in full.
     """},
    {".claude/skills/show/SKILL.md",
     """
     ---
     name: show
     description: Read this repo's open questions in full, or one by id. Use on /show, or when the person asks to see a question or what the mice are asking here.
     ---

     No argument → run exactly this:

         whiska show

     Every open question of this repo in full, oldest first, each saying why it
     is not being delivered, with anything orphaned or still on the doorstep
     underneath.

     An id passed ($ARGUMENTS is not empty) → run exactly this instead:

         whiska show $ARGUMENTS

     #{String.trim(@verbatim)} Answering is the person's move: never reply to
     a question, guess an answer, or act on one on their behalf.

     One exception, only with an id: when that question ends in 4 or fewer
     lettered options, offer them with the AskUserQuestion tool exactly as
     `whiska-delivered` describes, and relay the pick with
     `whiska reply <id> "<the letter and its label>"`. Bare `show` prints
     several questions, and no single picker can stand for all of them, so it
     gets none.
     """},
    {".claude/skills/reply/SKILL.md",
     """
     ---
     name: reply
     description: Answer a question one of this repo's mice is waiting on. Use when the person has decided what to tell a mouse, or on /reply.
     ---

     Run exactly this:

         whiska reply $ARGUMENTS

     No id spelled out — they are answering a question you just showed them →
     the id is the one from that delivered line:

         whiska reply <id> <what they said>

     The text is the person's own words, or the option they picked — never
     your summary of them or an answer you worked out: answering is their
     move, and this only carries it. Show the command's output verbatim and
     stop. If it says a hold was lifted, that mouse was on hold and the answer
     is what picks it up.

     A mouse is answered only this way: never with `herdr agent prompt` into
     its pane, never with `send-to-worktree`. Talking it over with the person
     first is fine; what that talk produces goes out as the reply.
     """},
    {".claude/skills/dismiss/SKILL.md",
     """
     ---
     name: dismiss
     description: Close one of this repo's questions without answering it.
     disable-model-invocation: true
     ---

     Run exactly this, with the id the person gave:

         whiska dismiss $ARGUMENTS

     Show its output verbatim and stop. This is the person's command: run it
     only when they ask for that question to be dismissed, never on your own
     reading that it looks handled. A question the person has not answered
     stays as it is; Whiska supersedes it itself when that mouse's next message
     arrives.
     """},
    {".claude/skills/away/SKILL.md",
     """
     ---
     name: away
     description: Stop every delivery on this machine until you resume; mice keep working.
     disable-model-invocation: true
     ---

     Run exactly this:

         whiska away

     Show its output verbatim and stop. Nothing is delivered to any main
     session until the person runs `resume`; mice keep working, and `inbox`
     keeps listing what they ask.
     """},
    {".claude/skills/focus/SKILL.md",
     """
     ---
     name: focus
     description: Let only one mouse's questions reach this repo's main session; /focus alone prints the current focus.
     disable-model-invocation: true
     ---

     Run exactly this, with the branch the person named, or with nothing to
     print the current focus:

         whiska focus $ARGUMENTS

     Show its output verbatim and stop. Only that mouse's questions reach this
     session now; the rest wait, still listed by `inbox`, and a question
     already delivered from another mouse no longer blocks the focused one.
     `resume` ends it. The branch is the person's choice: never pick one
     yourself.
     """},
    {".claude/skills/hold/SKILL.md",
     """
     ---
     name: hold
     description: Stop one mouse where it is and park its questions, undelivered, until you resume it.
     disable-model-invocation: true
     ---

     Run exactly this, with the branch the person named:

         whiska hold $ARGUMENTS

     Show its output verbatim and stop. The mouse's next tool call is refused
     and it ends its turn; its questions sit in the inbox marked held; it is
     never offered for landing. `resume <branch>` lifts it. Never hold a
     branch the person did not name.
     """},
    {".claude/skills/resume/SKILL.md",
     """
     ---
     name: resume
     description: End away and this repo's focus, or lift one mouse's hold.
     disable-model-invocation: true
     ---

     Run exactly this, with the branch the person named or nothing at all:

         whiska resume $ARGUMENTS

     Show its output verbatim and stop. With no branch it ends away and this
     repo's focus, and what waited arrives oldest first. With a branch it lifts
     that mouse's hold and, when the mouse stopped because of the hold, tells
     it to carry on from where it stopped; a mouse that was waiting on an
     answer gets no line, and the output names the question to reply to.
     """}
  ]

  # The long-named reading skills the words replace. `whiska init` removes a
  # plain file of these; one reached through a symlink is the person's and
  # stays (ADR-0056).
  @retired_skills [
    ".claude/skills/whiska-questions/SKILL.md",
    ".claude/skills/whiska-reply/SKILL.md"
  ]

  # The same eight, as plain commands at a shell. Each is a two-line spelling
  # of `whiska <word>` that resolves the binary the way the shim does, written
  # into a directory of Whiska's own so a generic word never lands among other
  # programs, and skipped where one already answers to the word.
  @commands ~w(inbox show reply dismiss focus away hold resume)

  @command_header """
  #!/usr/bin/env bash
  # One of Whiska's one-word commands, written by `whiska init --global`: a
  # spelling of `whiska WORD` for the shell. Resolves the binary the way the
  # hook shim does; WHISKA_BIN overrides the lookup.

  """

  @command_exec """
  if [ -z "$whiska_bin" ]; then
    echo "whiska: not found - install it, or set WHISKA_BIN" >&2
    exit 1
  fi
  exec "$whiska_bin" WORD "$@"
  """

  # The three worktree skills (ADR-0046). Unlike the two above, these wrap
  # `herdr` rather than `whiska` — they are the half of the protocol that
  # creates a mouse and takes it down again, and Whiska ships them because
  # Whiska is what the protocol is for. ADR-0021 stands: there is still no
  # `whiska spawn`, and spawning still happens through a conversation.
  #
  # Read from files at compile time rather than written out here. They are long
  # prose, and one source of truth is the only way the shipped copy and the
  # committed copy cannot drift.
  @worktree_skills ~w(spawn-worktree send-to-worktree drop-worktree)

  # The finish pipeline (ADR-0055). It binds a mouse the same way its rules
  # do, and ships as a skill for the same reason the worktree skills are
  # files: it is long, and a session only needs it at the moment a turn is
  # ending.
  #
  # The spec binds a mouse at one moment too, after grilling and before it
  # builds. The person's grilling skill ships beside it so it has one copy
  # (ADR-0076).
  #
  # `whiska-delivered` is the one skill nobody types a slash command for: the
  # owl's delivered line triggers it by its shape — the leading 🐱 and the
  # number after `#` — which its description names in a quoted YAML string,
  # since unquoted a space followed by `#` starts a comment and cut the listing
  # off before every example. Its two finished pickers ship beside it and are
  # read only when the line says finished.
  @committed_skills @worktree_skills ++ ~w(whiska-delivered whiska-finish grilling whiska-spec)

  # The source is `priv/skills/`, not this repo's own `.claude/skills/`. They
  # are build inputs, and a repo installed globally (ADR-0056) has no committed
  # `.claude/` to read them out of — sourcing them there made `whiska init
  # --global` on this repo delete the files the next build needed. The
  # destination is unchanged: `.claude/skills/<name>/SKILL.md` under whichever
  # scope root is being written.
  @skill_source "priv/skills"

  # SKILL.md first, then whatever it reads on demand, in name order.
  @committed_sources for name <- @committed_skills,
                         file <-
                           ["SKILL.md"] ++
                             ("#{@skill_source}/#{name}/*.md"
                              |> Path.wildcard()
                              |> Enum.map(&Path.basename/1)
                              |> Enum.reject(&(&1 == "SKILL.md"))
                              |> Enum.sort()),
                         do: "#{name}/#{file}"

  for source <- @committed_sources do
    @external_resource "#{@skill_source}/#{source}"
  end

  @committed_skill_files for source <- @committed_sources,
                             do:
                               {".claude/skills/#{source}",
                                File.read!("#{@skill_source}/#{source}")}

  # A file added beside a skill is a new build input, which @external_resource
  # cannot see until something already listed changes.
  def __mix_recompile__? do
    "#{@skill_source}/*/*.md" |> Path.wildcard() |> Enum.count() !=
      length(@committed_sources)
  end

  @doc """
  The shell that finds the whiska binary: `WHISKA_BIN`, then `PATH`, then
  `~/.local/bin`. Shared by the shim, both status scripts and the owl's
  wrapper, so they all resolve identically.
  """
  @spec resolve_whiska() :: String.t()
  def resolve_whiska, do: @resolve_whiska

  @doc "The shell that finds the Erlang runtime; shared the same way."
  @spec resolve_escript() :: String.t()
  def resolve_escript, do: @resolve_escript

  @doc "The Claude Code matcher Whiska registers for."
  @spec matcher() :: String.t()
  def matcher, do: @matcher

  @doc "Where the shim lives, relative to the repo root."
  @spec shim_path() :: Path.t()
  def shim_path, do: @shim_path

  @doc """
  The hook command that goes into `settings.json`.

  Names only the shim, via `$CLAUDE_PROJECT_DIR`, so the committed file is the
  same on every machine.
  """
  @spec command() :: String.t()
  def command, do: @command

  @doc """
  The same, for one scope: the repo's copy names the shim through
  `$CLAUDE_PROJECT_DIR`, the global copy names `$HOME` (ADR-0056).
  """
  @spec command(scope()) :: String.t()
  def command(:repo), do: @command
  def command(:global), do: @global_command

  @doc """
  Where a scope's files are rooted.

  The relative paths are the same either way — `.claude/hooks/whiska.sh` is one
  file in two places — so the scope is only ever the root it hangs off.
  """
  @spec root(scope(), Path.t() | nil) :: Path.t()
  def root(scope, repo_root \\ nil)
  def root(:repo, repo_root), do: repo_root
  def root(:global, _repo_root), do: Whiska.ServiceManager.user_home()

  @doc """
  The Stop hook command: the same shim, told it is a `stop`.

  This is the doorstep writer (ADR-0036). No matcher — a Stop hook has no tool
  to match on; it fires on every finished turn.
  """
  @spec stop_command() :: String.t()
  def stop_command, do: @stop_command

  @doc "The Stop hook command for one scope (ADR-0056)."
  @spec stop_command(scope()) :: String.t()
  def stop_command(:repo), do: @stop_command
  def stop_command(:global), do: @global_stop_command

  @doc """
  The UserPromptSubmit hook command: the same shim, told it is a
  `user-prompt-submit`. It hands a mouse the answer the person saved for it
  (ADR-0080).
  """
  @spec prompt_command(scope()) :: String.t()
  def prompt_command(scope \\ :repo)
  def prompt_command(:repo), do: @prompt_command
  def prompt_command(:global), do: @global_prompt_command

  @doc """
  The SessionStart hook command: the same shim, told it is a `session-start`.
  It prints the rules for the session's role (ADR-next-rules-arrive-by-role).
  """
  @spec session_start_command(scope()) :: String.t()
  def session_start_command(scope \\ :repo)
  def session_start_command(:repo), do: @session_start_command
  def session_start_command(:global), do: @global_session_start_command

  @doc """
  The shim script's contents.

  Resolves the binary and the Erlang runtime when the hook fires, and allows the
  call rather than denying it when Whiska is not installed.
  """
  @spec shim() :: String.t()
  def shim, do: @shim

  @doc """
  The shim for one scope.

  The global copy carries one thing the committed one does not: it stands down
  for a repo that wires Whiska itself, so a repo with both installs does not
  deny twice and leave two questions on the doorstep for one turn (ADR-0056).
  """
  @spec shim(scope()) :: String.t()
  def shim(:repo), do: @shim
  def shim(:global), do: @global_shim

  @doc """
  Where an older Whiska's review loop lives, relative to the repo root.

  Retired (ADR-0049): finishing is the pipeline the `whiska-finish` skill
  teaches and the `finish` part of `CLAUDE.md` points at (ADR-0055), run by the
  mouse itself. The path is kept so a `Stop` entry naming it
  is recognised as Whiska's and dropped, and so `whiska doctor` can say a file
  left on disk is no longer run by anything.
  """
  @spec review_loop_path() :: Path.t()
  def review_loop_path, do: @review_loop_path

  @doc """
  Where the script herdr's tab bar runs lives: the whiska home, beside the
  owl's wrapper and the open-houses record.

  Machine-level, because the line is (ADR-0048). No repo owns it, and `whiska
  init` never writes it.
  """
  @spec herdr_status_path() :: Path.t()
  def herdr_status_path, do: Path.join(Whiska.OpenHouses.home(), @herdr_status_name)

  @doc "The script's contents (ADR-0048)."
  @spec herdr_status_script() :: String.t()
  def herdr_status_script, do: @herdr_status_script

  @doc "Seconds between the tab bar's runs of it."
  @spec herdr_status_interval() :: pos_integer()
  def herdr_status_interval, do: @herdr_status_interval

  @doc "Seconds herdr waits before clearing the entry."
  @spec herdr_status_timeout() :: pos_integer()
  def herdr_status_timeout, do: @herdr_status_timeout

  @doc """
  The herdr config entry that draws the line — what the person pastes into
  `~/.config/herdr/config.toml` and commits with their dotfiles (ADR-0048).

  Whiska ships the script and never edits this file: the config is
  machine-global and the person's, and a per-repo `init` writing into it is
  exactly the boundary ADR-0016 forbids.
  """
  @spec tab_bar_right_snippet() :: String.t()
  def tab_bar_right_snippet do
    """
    [ui]
    tab_bar_right = [
      { type = "command", command = "#{herdr_status_path()}", interval_seconds = #{@herdr_status_interval}, timeout_seconds = #{@herdr_status_timeout} },
    ]
    tab_bar_right_separator = " · "
    """
  end

  @doc """
  Which pieces of the global install are on disk right now (ADR-0056).

  Three, and they are read rather than assumed because each can be removed on
  its own: the four hooks and the statusline in `~/.claude/settings.json`, and
  the skills. `whiska doctor` turns a half-written
  answer into a warning; `whiska init` uses it only to say whether the global
  install is there at all.
  """
  @spec global_state() :: %{
          hooks?: boolean(),
          statusline?: boolean(),
          skills?: boolean(),
          links: [{Path.t(), Path.t()}]
        }
  def global_state do
    home = root(:global)
    settings = read_json(Path.join(home, ".claude/settings.json"))

    %{
      hooks?:
        wired?(settings, "PreToolUse", command(:global)) and
          wired?(settings, "Stop", stop_command(:global)) and
          wired?(settings, "UserPromptSubmit", prompt_command(:global)) and
          wired?(settings, "SessionStart", session_start_command(:global)) and
          File.exists?(Path.join(home, @shim_path)),
      statusline?:
        statusline_command_in(settings) == statusline_command(:global) and
          File.exists?(Path.join(home, @statusline_path)),
      skills?: Enum.all?(skills(:global), fn {rel, _} -> File.exists?(Path.join(home, rel)) end),
      links: global_links()
    }
  end

  @global_pieces [:hooks?, :statusline?, :skills?]

  @doc "Is any of the global install there? Part of one still counts."
  @spec global_installed?() :: boolean()
  def global_installed?,
    do: global_state() |> Map.take(@global_pieces) |> Map.values() |> Enum.any?()

  @doc """
  Which of the paths the global install writes are symlinks, and where each
  points.

  A dotfiles repo is the usual reason: `~/.claude/CLAUDE.md` and
  `~/.claude/settings.json` are links into it. Every write goes through the
  link and changes the target in place, so the person's next move after an
  install is to commit it where it actually landed — which is what this is for.
  """
  @spec global_links() :: [{Path.t(), Path.t()}]
  def global_links do
    home = root(:global)

    paths =
      [".claude/CLAUDE.md", ".claude/settings.json", ".claude/skills", ".claude/hooks"] ++
        [@shim_path, @statusline_path] ++ Enum.map(skills(:global), &elem(&1, 0))

    for rel <- paths,
        {:ok, target} <- [:file.read_link(Path.join(home, rel))],
        do: {rel, to_string(target)}
  end

  defp read_json(path) do
    with {:ok, raw} <- File.read(path),
         {:ok, settings} when is_map(settings) <- JSON.decode(raw) do
      settings
    else
      _ -> %{}
    end
  end

  defp wired?(settings, event, expected) do
    settings
    |> entries(event)
    |> Enum.any?(&(ours?(&1) and our_command(&1) == expected))
  end

  defp statusline_command_in(%{"statusLine" => %{"command" => command}}) when is_binary(command),
    do: command

  defp statusline_command_in(_settings), do: nil

  # `~/.claude/settings.json` is the person's file and `whiska init` now reads it
  # whatever is in it. Anything but a list of entries is not a hook Whiska can
  # recognise, and is no reason to take a command down.
  defp entries(settings, event) do
    case settings do
      %{"hooks" => %{^event => entries}} when is_list(entries) -> entries
      _ -> []
    end
  end

  defp our_command(%{"hooks" => hooks}) do
    Enum.find_value(hooks, fn
      %{"command" => command} when is_binary(command) -> command
      _ -> nil
    end)
  end

  @doc "Write the script into the whiska home, executable."
  @spec write_herdr_status() :: :ok | {:error, File.posix()}
  def write_herdr_status do
    path = herdr_status_path()

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, @herdr_status_script) do
      File.chmod(path, 0o755)
    end
  end

  @doc "Where the project statusline script lives, relative to the repo root."
  @spec statusline_path() :: Path.t()
  def statusline_path, do: @statusline_path

  @doc "The statusLine command that goes into `settings.json`; names only the script."
  @spec statusline_command() :: String.t()
  def statusline_command, do: @statusline_command

  @doc "The statusLine command for one scope (ADR-0056)."
  @spec statusline_command(scope()) :: String.t()
  def statusline_command(:repo), do: @statusline_command
  def statusline_command(:global), do: @global_statusline_command

  @doc """
  Where the global statusline Whiska displaced is kept, relative to the home.

  A `statusLine` is one value, not a list, so installing globally would
  otherwise simply lose the person's own line. Both scripts read it.
  """
  @spec base_statusline_path() :: Path.t()
  def base_statusline_path, do: @base_statusline_path

  @doc "The statusline script's contents (ADR-0027)."
  @spec statusline_script() :: String.t()
  def statusline_script, do: @statusline_script

  @doc """
  Which version of the statusline script this build ships (ADR-0059).

  The script carries it in a `# whiska-statusline: v<n>` line, which is how
  `whiska doctor` tells a repo's copy apart from this one.
  """
  @spec statusline_version() :: pos_integer()
  def statusline_version, do: @statusline_version

  @doc "The version stamp in a copy of the script, or `nil` when it carries none."
  @spec statusline_version_of(String.t()) :: pos_integer() | nil
  def statusline_version_of(contents) when is_binary(contents) do
    case Regex.run(~r/^#\s*whiska-statusline:\s*v(\d+)/m, contents) do
      [_, version] -> String.to_integer(version)
      nil -> nil
    end
  end

  @doc """
  Seconds between statusline redraws, written beside the command (ADR-0044).

  It is what keeps the mice and a second question honest while the session
  sits idle.
  """
  @spec statusline_refresh_interval() :: pos_integer()
  def statusline_refresh_interval, do: @statusline_refresh_interval

  @doc """
  The skills `whiska init` writes, as `{path, contents}`.

  Two kinds, and both are one skill per fixed command rather than bash the model
  composes itself (ADR-0022): the reading skills that wrap `whiska`, and the
  three worktree skills that wrap `herdr` (ADR-0046). `whiska-finish` and
  `whiska-spec` are neither: they are steps a mouse's rules point at (ADR-0055).
  Nor is `grilling`, the person's own skill, shipped so it has one copy.
  """
  @spec skills() :: [{Path.t(), String.t()}]
  def skills, do: @skills ++ @committed_skill_files

  @doc """
  The skills one scope writes: all nine in both, because the global install
  is the only source of them on a machine that has it (ADR-0056).
  """
  @spec skills(scope()) :: [{Path.t(), String.t()}]
  def skills(_scope), do: skills()

  @doc "The skills an older Whiska shipped and this one removes where they are plain files."
  @spec retired_skills() :: [Path.t()]
  def retired_skills, do: @retired_skills

  @doc "The eight one-word commands, in the order the help lists them."
  @spec commands() :: [String.t()]
  def commands, do: @commands

  @doc "Where the commands are written: `bin` under the whiska home, never `~/.local/bin`."
  @spec commands_dir() :: Path.t()
  def commands_dir, do: Path.join(Whiska.OpenHouses.home(), "bin")

  @doc "The script behind one word."
  @spec command_script(String.t()) :: String.t()
  def command_script(word) when word in @commands do
    @command_header <> @resolve_whiska <> String.replace(@command_exec, "WORD", word)
  end

  @doc """
  Write the eight commands into `dir`, executable, skipping a word that already
  resolves on this PATH to anything but Whiska's own wrapper there, and a word
  where a symlink sits at the path — the whiska home is writable by a build
  mouse, and a write through a planted link would land in whatever it points
  at. Returns `{written, skipped}`, each skipped word with the program it would
  have shadowed or the link it would have written through.
  """
  @spec write_commands(Path.t()) ::
          {:ok, {[String.t()], [{String.t(), Path.t()}]}} | {:error, File.posix()}
  def write_commands(dir \\ commands_dir()) do
    with :ok <- File.mkdir_p(dir) do
      {skipped, free} =
        @commands
        |> Enum.map(&{&1, taken_by(dir, &1)})
        |> Enum.split_with(fn {_word, taken} -> taken != nil end)

      Enum.reduce_while(free, {:ok, {[], skipped}}, fn {word, nil}, {:ok, {written, skip}} ->
        path = Path.join(dir, word)

        with :ok <- File.write(path, command_script(word)),
             :ok <- File.chmod(path, 0o755) do
          {:cont, {:ok, {written ++ [word], skip}}}
        else
          error -> {:halt, error}
        end
      end)
    end
  end

  defp taken_by(dir, word) do
    path = Path.join(dir, word)

    case :file.read_link(path) do
      {:ok, target} ->
        "a symlink at #{path} → #{target}"

      {:error, _not_a_link} ->
        case System.find_executable(word) do
          nil ->
            nil

          found ->
            if Whiska.Layout.canonical(found) == Whiska.Layout.canonical(path),
              do: nil,
              else: found
        end
    end
  end

  @doc "Take the eight commands back out of `dir`. Returns the words that were there."
  @spec remove_commands(Path.t()) :: [String.t()]
  def remove_commands(dir \\ commands_dir()) do
    removed = Enum.filter(@commands, &File.regular?(Path.join(dir, &1)))
    Enum.each(removed, &File.rm(Path.join(dir, &1)))
    File.rmdir(dir)
    removed
  end

  @doc "The three worktree skills, as the paths both scopes write them to."
  @spec worktree_skill_paths() :: [Path.t()]
  def worktree_skill_paths,
    do: for(name <- @worktree_skills, do: ".claude/skills/#{name}/SKILL.md")

  @doc """
  Merge Whiska's hook into an existing settings map.

  Idempotent, and surgical: unrelated settings, unrelated hook events, and other
  people's `PreToolUse` entries all survive untouched. A previously-installed
  Whiska entry is replaced rather than duplicated — including one written before
  the matcher was widened, and one written before the shim existed, which is why
  the entry is recognised by its command rather than by its matcher.
  """
  @spec merge(map()) :: map()
  def merge(settings), do: merge(settings, :repo)

  @doc """
  The same, into one scope's `settings.json` — the repo's, or the person's own
  `~/.claude/settings.json` (ADR-0056).

  Global is where "never clobber the person's other settings" earns its keep:
  that file is theirs, holds their model, permissions and hooks of their own,
  and the merge is the same surgical one either way.
  """
  @spec merge(map(), scope()) :: map()
  def merge(settings, scope) when is_map(settings) do
    pre_tool_use = %{
      "matcher" => @matcher,
      "hooks" => [%{"type" => "command", "command" => command(scope)}]
    }

    stop = %{"hooks" => [%{"type" => "command", "command" => stop_command(scope)}]}
    prompt = %{"hooks" => [%{"type" => "command", "command" => prompt_command(scope)}]}

    session_start = %{
      "hooks" => [%{"type" => "command", "command" => session_start_command(scope)}]
    }

    settings
    |> sound_hooks()
    |> put_ours("PreToolUse", [pre_tool_use])
    |> put_ours("Stop", [stop])
    |> put_ours("UserPromptSubmit", [prompt])
    |> put_ours("SessionStart", [session_start])
    |> put_statusline(scope)
  end

  @doc """
  The `statusLine` command this install is about to push aside, or `nil`.

  Nothing when there is none and nothing when the one there is already ours —
  a re-init must not record Whiska's own line as the person's.
  """
  @spec displaced(map()) :: String.t() | nil
  def displaced(settings) when is_map(settings) do
    case settings["statusLine"] do
      %{"command" => command} when is_binary(command) ->
        if String.contains?(command, @statusline_path), do: nil, else: command

      _ ->
        nil
    end
  end

  @doc """
  Take Whiska back out of a settings map — `whiska uninstall`.

  The mirror of `merge/2`: our hook entries go, everyone else's stay, and our
  `statusLine` is replaced by `base` — the line this install displaced, read
  back from where it was recorded — or removed outright when there is none. A
  `statusLine` that was never ours is left exactly alone.
  """
  @spec unmerge(map(), String.t() | nil) :: map()
  def unmerge(settings, base) when is_map(settings) do
    settings
    |> drop_ours("PreToolUse")
    |> drop_ours("Stop")
    |> drop_ours("UserPromptSubmit")
    |> drop_ours("SessionStart")
    |> restore_statusline(base)
  end

  defp drop_ours(settings, event) do
    case settings do
      %{"hooks" => %{^event => entries}} when is_list(entries) ->
        put_in(settings, ["hooks", event], Enum.reject(entries, &ours?/1))

      _ ->
        settings
    end
  end

  defp restore_statusline(settings, base) do
    case Map.get(settings, "statusLine") do
      %{"command" => command} when is_binary(command) ->
        cond do
          not String.contains?(command, @statusline_path) ->
            settings

          is_binary(base) and base != "" ->
            Map.put(settings, "statusLine", %{"type" => "command", "command" => base})

          true ->
            Map.delete(settings, "statusLine")
        end

      _ ->
        settings
    end
  end

  # A project statusLine is a single value, not a list, so there is no "beside
  # the others" here: one that is ours, or missing, is set; one that is somebody
  # else's is left exactly alone rather than replaced — including its refresh
  # interval, or its want of one.
  defp put_statusline(settings, scope) do
    entry = %{
      "type" => "command",
      "command" => statusline_command(scope),
      "refreshInterval" => @statusline_refresh_interval
    }

    case {scope, settings["statusLine"]} do
      # The global install takes the line over, because without it no repo gets
      # a board at all. What it displaces is kept beside the script, which runs
      # it first, so the person's own line survives (ADR-0056).
      {:global, _any} ->
        Map.put(settings, "statusLine", entry)

      {:repo, nil} ->
        Map.put(settings, "statusLine", entry)

      {:repo, %{"command" => command}} when is_binary(command) ->
        if String.contains?(command, @statusline_path),
          do: Map.put(settings, "statusLine", entry),
          else: settings

      {:repo, _unrecognised} ->
        settings
    end
  end

  defp put_ours(settings, event, entries) do
    others = settings |> entries(event) |> Enum.reject(&ours?/1)
    put_in(settings, ["hooks", event], others ++ entries)
  end

  # Whiska's own entries go in whatever was there; a `hooks` value that is not a
  # map of lists is not something it can add to, and is replaced rather than
  # reached into.
  defp sound_hooks(%{"hooks" => hooks} = settings) when is_map(hooks), do: settings
  defp sound_hooks(settings), do: Map.put(settings, "hooks", %{})

  # Ours is whatever runs a `whiska ... hook ...`, or the shim that does it for
  # us, or the retired review loop — a settings.json from the version that gave
  # the loop its own Stop entry has that entry removed on the next init rather
  # than left to fire beside the shim's.
  #
  # Ours is also — whatever matcher it was registered with, and whether or not the shim
  # took an argument when it was written. Matching on the matcher would fail to
  # recognise an entry written by an older version and would stack a duplicate
  # beside it.
  defp ours?(%{"hooks" => hooks}) when is_list(hooks) do
    Enum.any?(hooks, fn
      %{"command" => command} when is_binary(command) ->
        String.contains?(command, "whiska hook") or
          String.contains?(command, "hook pre-tool-use") or
          String.contains?(command, @shim_path) or
          String.contains?(command, @review_loop_path)

      _ ->
        false
    end)
  end

  defp ours?(_), do: false
end
