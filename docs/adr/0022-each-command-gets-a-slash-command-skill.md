# Each command gets a slash-command skill, not model-composed bash

A `whiska` command the main session runs on the person's behalf is wrapped in a skill of
fixed commands, and the model never composes the bash itself. Translating plain English
into the right call every time is the failure mode the old worktree relay taught: less
surface for the model to get wrong or forget. A wrapper may choose between two
written-out commands on one written-out condition; it never composes a command out of what
it read, summarises the output, or answers on the person's behalf (ADR-0081).

There is no `whiska spawn`. Spawning a mouse is a judgment call — which mode, which model,
whether this is worth a worktree — and that belongs in a conversation with the main
session, not in a bare command. `spawn-worktree`, `send-to-worktree` and `drop-worktree`
are skills of fixed `herdr` commands for the same reason (ADR-0056).

## The commands and their skills

The person's eight one-word commands — `inbox`, `show`, `reply`, `dismiss`, `focus`,
`away`, `hold`, `resume` — are written by `whiska init --global` under the whiska home,
skipped where another program already answers to the word, and ship as the same eight
slash commands (ADR-0079). Six of them are only ever the person's to type and never load
into a session's context (ADR-0081); `show` and `reply` stay where the main session can
reach them. `/inbox` wraps `whiska waiting`, a machine-wide command with no right repo to
run in: it runs only when the person types it, which is the person asking.

`whiska-delivered` is installed beside them but nobody types it: the owl's delivered line
carries no command, so the skill's description names the line's shape and Claude Code
picks it by description. Its body is the same thin wrapper — show the question in full,
stop, never answer for the person.

Commands typed before a session exists (`init`, `start`, `doctor`, `owl`) get no skill,
since `whiska start` creates the session. `jump` and `watch` get none either: nothing runs
them on the person's behalf.

## An answer goes through `whiska reply` and nothing else

Never `herdr agent prompt` into the mouse's pane, never `send-to-worktree`, which is for a
new idea. Text typed into a pane reaches the mouse, but the question stays `sent`: it
keeps the one delivery slot (ADR-0008) and every later question sits behind it. That cost
six minutes of a question nobody could see on 2026-09-29. A `PreToolUse` guard was
rejected: the hook cannot tell an answer from a new idea, since `send-to-worktree` types
into a live pane legitimately, and the decision would have to read the questions table,
which no rule does. So this stays a rule in the skills and the main session's rules.

## Options are lettered lines, read against the branch last shown

A reply that offers choices ends with them as plain lettered lines, recommended first,
then "Or write anything else and it goes to <branch>." The person's reply is read against
the branch last shown:

- Only a letter or an option's word — "A", "land", "land it" — does that option. On a
  decision the skill relays it with the fixed `whiska reply <id> "<the letter and its
  label>"`; the options came from the mouse, and the person's own words go word for word.
- "hold" runs `whiska hold <branch>`; `show <id>` brings the options back.
- Anything longer is the person's own words, and goes to that branch as written, unless it
  is plainly meant for the main session.
- Two options could fit, or another delivered line arrived since → one line back, naming
  the branch.
- Drop confirms in one line.

A finished line has nothing to reply to, so its options are Whiska's own, the same few
every time, written out in the skill and chosen by the branch line `whiska show` prints:
land here, open a merge request, drop it, with a commit first where files are not
committed, and none where the branch has nothing on it (ADR-0074). The pick is acted on,
not relayed: landing cherry-picks the branch's own commits onto the current branch, oldest
first, its merges from the base skipped; a merge request carries the finished message as
its body, since the branch's own session had the context to write it (ADR-0060). That is
the main session doing work on a branch, which the rules allow because the person picked
it, and the guard is that the options appear for a finished line and nothing else.

A repo names its usual choice with a line like `finish: land here` under a `## Finish`
heading in its own `CLAUDE.md`, and that option is recommended instead. It is a heading
the person writes, not a part of the rules: which ending a person prefers is not
protocol, and no code reads it — the repo's `CLAUDE.md` is already in the main session's
context.

## Why plain lines and not a picker

The options were once Claude Code's `AskUserQuestion` picker. In one day the person got
28 of them and cancelled or bypassed 13: a cancel came back as "the user doesn't want to
proceed", so "not yet" read as "no"; the picker covered the message it followed; and while
it was up the screen had no prompt box, so all delivery stopped (ADR-0047). Tools that
pass answers between sessions ask in plain text. What the picker gave — one keypress, no
typos — plain letters keep, and the delivery it held by accident is held on purpose: a
finished line holds the slot until the person writes something (ADR-0008), so "the branch
last shown" is one branch. Claude Code's own pickers — plan mode, permission prompts — are
outside Whiska and still hold delivery.

## Considered options

- **The model composes the bash from the conversation.** The relay's failure mode.
- **A `whiska spawn` command.** A judgment with no thinking behind it.
- **A `PreToolUse` guard against typing into a mouse's pane.** It cannot tell an answer
  from `send-to-worktree`.
- **A picker for the options.** Above.
- **A shipped part carrying the finish default.** Whiska writing a preference into every
  repo, and `keep` on a whole part to change one word.
- **`whiska history <branch>`.** Useful occasionally, not daily; built if it is missed.

Folded in on 2026-10-08: 0021 (its text is in git history).
