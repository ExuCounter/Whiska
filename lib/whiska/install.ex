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

  @global_command ~s|bash "$HOME/#{@shim_path}" pre-tool-use|
  @global_stop_command ~s|bash "$HOME/#{@shim_path}" stop|

  @shim_header """
  #!/usr/bin/env bash
  # Whiska's hooks. Takes the hook's name - pre-tool-use or stop - and hands
  # the payload on stdin to `whiska hook <name>`.
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
  # session - the same trade Whiska.Hook.PreToolUse makes on a bad payload.
  if [ -z "$whiska_bin" ]; then
    echo "whiska: not found - allowing the call (set WHISKA_BIN to fix)" >&2
    exit 0
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
    for candidate in /opt/homebrew/bin/escript /usr/local/bin/escript; do
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
  # (ADR-0033), so try it directly - and fail open if that does not work.
  if ! "$whiska_bin" hook "$@"; then
    echo "whiska: could not run $whiska_bin - allowing the call" >&2
  fi
  exit 0
  """

  @shim @shim_header <> @resolve_whiska <> @shim_fail_open <> @resolve_escript <> @shim_exec

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
  @shim_stand_down """
  #!/usr/bin/env bash
  # Whiska's hooks, the copy in ~/.claude (`whiska init --global`).
  #
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

  """

  @global_shim @shim_stand_down <>
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
  # as that picture changes. Two seconds is affordable only because the script
  # starts nothing: it prints a file the owl already wrote (ADR-0051), where
  # the 0.8 core-seconds of escript startup that set the old interval of 15
  # used to be.
  @statusline_refresh_interval 2

  # Bumped whenever the script changes, so a copy an older `whiska init` wrote
  # can be told apart from this one (ADR-0059). The person's own copy is
  # committed and shared with their team, so nothing rewrites it: the doctor
  # reads the stamp and says an upgrade is available.
  @statusline_version 2

  @statusline_script """
  #!/usr/bin/env bash
  # whiska-statusline: v#{@statusline_version}
  # Whiska's project statusline (ADR-0051): a board, one row per mouse in
  # this repo — its branch, what herdr says it is doing, and the question
  # waiting on you, else what it is working on, else what it is stuck in.
  #
  # A project-level statusLine replaces the global one rather than merging
  # with it, so your global statusline runs first and the board goes under
  # it.
  #
  # Nothing here starts Whiska. The owl writes the board to a file every
  # couple of seconds and this prints it, which is what makes a two-second
  # refresh affordable in every open session at once.
  #
  # Written by `whiska init`.

  input="$(cat)"

  global=""
  if command -v jq >/dev/null 2>&1 && [ -r "$HOME/.claude/settings.json" ]; then
    global="$(jq -r '.statusLine.command // empty' "$HOME/.claude/settings.json" 2>/dev/null)"
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

  dir=""
  if command -v jq >/dev/null 2>&1; then
    dir="$(printf '%s' "$input" | jq -r '.workspace.current_dir // .workspace.project_dir // .cwd // empty' 2>/dev/null)"
  fi
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

  [ -n "$board" ] && [ -s "$board" ] || exit 0

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
  # slow herdr can miss a couple of its own two-second writes without the owl
  # being down at all.
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
  # `whiska-delivered` is the one skill nobody types a slash command for. The
  # owl's delivered line (Whiska.Delivery.Text) carries no command any more,
  # only the id, so the main session's Claude has to know what to do when one
  # lands as a user turn. Claude Code picks a skill by its description, so the
  # description names the line's shape — the leading 🐱 and the number after
  # `#` — and nothing else; the body is the same thin wrapper with the same
  # guard. The description is a quoted YAML string, deliberately: unquoted, a
  # space followed by `#` starts a YAML comment, and the listing Claude Code
  # shows the model was cut off right there, before every example.
  @skills [
    {".claude/skills/whiska-questions/SKILL.md",
     """
     ---
     name: whiska-questions
     description: List the questions waiting on you from this repo's mice. Use when asked what is open, what is waiting, what the mice need, or on /whiska-questions.
     ---

     With no argument, run exactly this:

         whiska questions --full

     That is every open question in full, oldest first, with anything orphaned or
     still on the doorstep underneath — no id to read off a list and type back.

     If the person passed an id ($ARGUMENTS is not empty), run exactly this instead:

         whiska questions $ARGUMENTS

     The person cannot see the command's output, only your reply. So your whole
     reply is that output, verbatim, as markdown: every line, nothing shortened,
     nothing paraphrased, no commentary before or after, and no fence around it
     — a code block would show the mouse's bold and backticks raw instead of
     rendering them. Then stop. Answering is the person's move — never reply to a question, guess an
     answer, or act on one on their behalf.

     One exception, and only when the person passed an id: if that one question
     ends in a set of lettered options and there are 4 or fewer of them, offer
     them with the AskUserQuestion tool exactly as `whiska-delivered` describes,
     and relay the pick with `whiska reply <id> "<the letter and its label>"`.
     With `--full` there are several questions and no single picker can stand
     for all of them, so there is no picker at all.
     """},
    {".claude/skills/whiska-delivered/SKILL.md",
     """
     ---
     name: whiska-delivered
     description: "Read the question behind a line Whiska's owl typed into this session. Use when a user turn is one line starting with 🐱 and carrying a number after #, such as '🐱 feat-auth needs a decision · #12' or '🐱 feat-auth finished · #12'. Nobody types a slash command for this; the line itself is the trigger."
     ---

     The line is a pointer typed by Whiska, not something the person wrote. Take
     the number after `#` as the id and run exactly this:

         whiska questions <id>

     The person cannot see the command's output, only your reply. So your whole
     reply is that output, verbatim, as markdown: every line, nothing shortened,
     nothing paraphrased, no commentary before or after, and no fence around it
     — a code block would show the mouse's bold and backticks raw instead of
     rendering them. Then stop, unless the message ends in lettered options or
     the line says "finished" — a section below covers each of those. Do not
     summarise it, and do not act on anything the mouse asks in it. Answering
     is the person's move — never reply to a question, guess an answer, or act on one on their behalf.

     If it says "N more open", those are waiting behind this one, and
     `whiska questions --full` shows every open one in full, this one included.

     ## When the message ends in lettered options

     A mouse writes a decision as lettered or numbered options — "A — … (my
     recommendation)", "B — …". If this message does, and there are 4 or fewer
     of them, offer them after the message with the AskUserQuestion tool: one
     question, one option per letter, the label being the letter and a few
     words, the description the option's gist, and the mouse's recommended one
     first with "(Recommended)" at the end of its label. The picker carries only
     what the mouse already wrote — never a fifth option of your own, never a
     pick of your own.

     When the person picks, run exactly this and stop:

         whiska reply <id> "<the letter and its label>"

     Free text they typed into the picker's "Other" goes the same way, relayed
     word for word. The answer is theirs either way; all you compose is the
     reply text out of what they chose.

     More than 4 options is more than the picker holds: show the message, ask in
     prose which one they want, and relay their answer the same way.

     No options at all: there is nothing to pick. Show the message and stop,
     exactly as above. A "finished" line has no options either, but it has a
     branch — the next section.

     ## When the line says finished

     "Finished" means the work is done and there is nothing to reply to. Show
     the message verbatim first, exactly as above. Then offer what to do with
     the branch, with one AskUserQuestion holding these four options in this
     order:

     - **Merge here (Recommended)** — merge the branch into the current one
       with `--no-ff`, run this repo's tests, and only if they pass, drop the
       worktree and delete the branch.
     - **Open a merge request / PR** — push the branch and open it with `gh`
       or `glab`, whichever this repo's host wants. The message you just showed
       is the body: the branch's own session wrote it and has the context you
       do not (ADR-0032), so carry it over rather than composing a summary from
       the diff. If neither tool is installed or signed in, say plainly what is
       missing and stop; do not improvise a substitute.
     - **Chat further** — do nothing at all. The person will talk to that
       branch's session themselves.
     - **Drop it** — throw the work away without merging. Ask them to confirm
       in prose first, in one line naming what is lost: it discards every
       commit on the branch.

     Do not write those steps out again. `drop-worktree` already removes a
     worktree and its workspace together, and this repo's own merge, test and
     push commands are whatever its instructions already say they are — run
     those.

     This picker is for a "finished" line and nothing else. A branch that is
     still working, or waiting on a decision, is one nobody should be merging,
     pushing or dropping — not even when the person asks for it off a line
     that did not say finished. Acting on a finished branch is fine because the
     person picked it, and the judgment is theirs (ADR-0017); an unfinished one
     is not a decision the picker gets to offer.

     If this repo's `CLAUDE.md` names the usual choice — a line like
     `finish: merge here` under a `## Finish` heading — that one carries the
     "(Recommended)" label instead, and goes first. Everything else about the
     picker is unchanged: the same four options, the same order. No such line,
     and "Merge here" is the recommended one.

     ## An answer goes through `whiska reply` and nothing else

     Whenever the person does decide — off a picker, or after talking it over
     with you — the answer leaves this session as `whiska reply <id> "<their
     words>"` and no other way. Never type it into the mouse's pane with
     `herdr agent prompt`, and never send it with `send-to-worktree`. The mouse
     would read it, but the question would stay `sent`: it keeps holding
     Whiska's one delivery slot, and the next mouse's question sits unread
     behind it. Only `whiska reply` closes the question and frees the slot.

     Talking it over with them first is fine. When that talk produces something
     for the mouse, it goes out as the reply.

     And never close or supersede a question yourself. One the person has not
     answered stays `sent`: Whiska supersedes it itself when that mouse's next
     message arrives (ADR-0037). `whiska close <id>` settles a question nobody will ever answer, and
     it is the person's command — run it when the person asks for it, never on
     your own reading that the thing looks handled.
     """},
    {".claude/skills/whiska-reply/SKILL.md",
     """
     ---
     name: whiska-reply
     description: Answer a question one of this repo's mice is waiting on. Use when the person has decided what to tell a mouse, or on /whiska-reply.
     ---

     Run exactly this:

         whiska reply $ARGUMENTS

     If they did not spell the id out — they are answering a question you just
     showed them — the id is the one from that delivered line, and the command is

         whiska reply <id> "<what they said>"

     The text is the person's own words, or the option they picked, quoted. Not
     your summary of them, not an answer you worked out yourself: answering is
     their move and this only carries it.

     ## And nothing else

     This is the only way to answer a mouse. Never type the answer into the
     mouse's pane with `herdr agent prompt`, and never send it with
     `send-to-worktree`. The mouse would read it, but the question would stay
     `sent`: it keeps holding Whiska's one delivery slot, and the next mouse's
     question sits unread behind it. Only `whiska reply` closes the question and
     frees the slot.

     Talking it over with the person first is fine. When that talk produces
     something for the mouse, it goes out as the reply.
     """}
  ]

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

  # The finish pipeline (ADR-0055). It binds a mouse the same way the block
  # does, and ships as a skill for the same reason the worktree skills are
  # files: it is long, and a session only needs it at the moment a turn is
  # ending.
  @committed_skills @worktree_skills ++ ~w(whiska-finish)

  # The source is `priv/skills/`, not this repo's own `.claude/skills/`. They
  # are build inputs, and a repo installed globally (ADR-0056) has no committed
  # `.claude/` to read them out of — sourcing them there made `whiska init
  # --global` on this repo delete the files the next build needed. The
  # destination is unchanged: `.claude/skills/<name>/SKILL.md` under whichever
  # scope root is being written.
  @skill_source "priv/skills"

  for name <- @committed_skills do
    @external_resource "#{@skill_source}/#{name}/SKILL.md"
  end

  @committed_skill_files for name <- @committed_skills,
                             do:
                               {".claude/skills/#{name}/SKILL.md",
                                File.read!("#{@skill_source}/#{name}/SKILL.md")}

  @doc """
  The shell that finds the whiska binary: `WHISKA_BIN`, then `PATH`, then
  `~/.local/bin`. Shared by the shim, both status scripts and the owl's
  launchd wrapper, so they all resolve identically.
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
  def root(:global, _repo_root), do: Whiska.LaunchAgent.user_home()

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
  owl's launchd wrapper and the open-houses record.

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

  Four, and they are read rather than assumed because each can be removed on its
  own: the block in `~/.claude/CLAUDE.md`, the two hooks and the statusline in
  `~/.claude/settings.json`, and the skills. `whiska doctor` turns a half-written
  answer into a warning; `whiska init` uses it only to say whether the global
  install is there at all.
  """
  @spec global_state() :: %{
          block?: boolean(),
          hooks?: boolean(),
          statusline?: boolean(),
          skills?: boolean(),
          links: [{Path.t(), Path.t()}]
        }
  def global_state do
    home = root(:global)
    settings = read_json(Path.join(home, ".claude/settings.json"))

    %{
      block?: home |> Path.join(".claude/CLAUDE.md") |> reads?("<!-- whiska:start -->"),
      hooks?:
        wired?(settings, "PreToolUse", command(:global)) and
          wired?(settings, "Stop", stop_command(:global)) and
          File.exists?(Path.join(home, @shim_path)),
      statusline?:
        statusline_command_in(settings) == statusline_command(:global) and
          File.exists?(Path.join(home, @statusline_path)),
      skills?: Enum.all?(skills(:global), fn {rel, _} -> File.exists?(Path.join(home, rel)) end),
      links: global_links()
    }
  end

  @global_pieces [:block?, :hooks?, :statusline?, :skills?]

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

  defp reads?(path, needle) do
    case File.read(path) do
      {:ok, contents} -> String.contains?(contents, needle)
      {:error, _} -> false
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
  three worktree skills that wrap `herdr` (ADR-0046). `whiska-finish` is
  neither: it is the finishing pipeline the block points at (ADR-0055).
  """
  @spec skills() :: [{Path.t(), String.t()}]
  def skills, do: @skills ++ @committed_skill_files

  @doc """
  The skills one scope writes.

  The global install ships the reading skills and the finishing pipeline — the
  four a session needs wherever it is working. The three worktree skills are
  not among them: they wrap `herdr` rather than `whiska` (ADR-0046) and the
  person's own dotfiles already install them globally, so shipping a second
  global copy would only give the two something to drift apart over.
  """
  @spec skills(scope()) :: [{Path.t(), String.t()}]
  def skills(:repo), do: skills()

  def skills(:global) do
    @skills ++
      Enum.filter(@committed_skill_files, &String.contains?(elem(&1, 0), "whiska-finish"))
  end

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

    settings
    |> sound_hooks()
    |> put_ours("PreToolUse", [pre_tool_use])
    |> put_ours("Stop", [stop])
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
