# Architecture

C4 diagrams for Whiska. `CONTEXT.md` is still the glossary and `docs/adr/` is still the
authority — these are a view onto both, not a third source of truth. Where a diagram and
an ADR disagree, the ADR wins.

| Level | File | Shows |
|---|---|---|
| 1 | [c4-context.md](c4-context.md) | Whiska between the person, Claude Code, herdr, git and launchd |
| 2 | [c4-containers.md](c4-containers.md) | Built against designed, as two boundaries |
| 3 | [c4-components-cli.md](c4-components-cli.md) | Inside the escript — hooks, init and the CLAUDE.md block, mode, questions, the statusline, doctor, the delivery-side commands, waiting and jump |
| 3 | [c4-components-owl.md](c4-components-owl.md) | Inside the owl — houses, herdr, doorstep, classification, delivery |
| — | [c4-dynamic-pretooluse.md](c4-dynamic-pretooluse.md) | One tool-call decision, end to end |
| — | [c4-dynamic-question-delivery.md](c4-dynamic-question-delivery.md) | A question from the doorstep to its answer |

**Built.** v0.0.1's plumbing — mouse identity as a marker file, a per-repo SQLite house,
worktree containment and sniff mode enforced through `PreToolUse` (ADR-0030). Then the
owl slice: the owl supervisor with one independently supervised house per project, each
house's herdr subscription and pane discovery, the doorstep and the `Stop` hook that
writes to it, collection on idle, and dead-mouse marking (ADR-0001, ADR-0036, ADR-0026).
Then delivery: `whiska start` recording the main session, the idle-gated queue that types
one question at a time into it, `reply` and `close`, and a newer question superseding its
mouse's earlier ones (ADR-0008, ADR-0037). Then `whiska questions` and the statusline, both
reading what is waiting — open and sent questions, orphaned ones apart, and what is still
on the doorstep — with the `/whiska-questions` slash command beside them (ADR-0027,
ADR-0022). Then `whiska mice`, and `whiska doctor`, which checks all of the above for one
repo and never repairs (ADR-0038). Then the owl's state shown always — watching, or down
(ADR-0027, second addendum). Then the open-houses record: the owl writes
which houses it has open to `~/.whiska/houses`, reopens them on the next `whiska owl`,
and a whiska is a house in that record with a live pane — the statusline, `whiska
waiting` and a doctor line all read it (ADR-0039). Then `launchd` supervision: `whiska owl install` writes a user LaunchAgent that
runs the owl with no arguments through a wrapper sharing the shim's runtime lookup,
restarts it only on a crash, and logs to `~/.whiska/owl.log`; `whiska owl stop`, `start`
and `uninstall` beside it; and the doctor's `launch agent` line (ADR-0040). Then the backstop
warning: when a house's 60 s backstop collects anything, it is something the idle trigger
should have brought a minute earlier, so the house warns and marks it in
`.git/whiska/backstop`, and the doctor reads that mark as one more line — the guard
against a dead trigger hiding behind a working last resort (ADR-0036, note of
2026-09-28). Then finishing, which is no longer a hook at all: `whiska init` writes a `finish` part
into the `CLAUDE.md` block, and a mouse runs it itself before it says `done` — the work
read back against the brief and the repo's decisions, the repo's checks run and fixed,
reviewers sent over its own diff, one more round, then the marker. `review-loop.sh` is
retired: nothing writes it, nothing chains it, and the doctor warns about a file left on
disk rather than removing it (ADR-0049, ADR-0042 superseded). Whiska itself still runs no
checks at all (ADR-0014 superseded). Then `whiska waiting` and `whiska jump`: one reading of every house in the
open-houses record — each open or sent question and each uncollected doorstep entry,
oldest first, with the mouse's pane — printed as lines or as `--json`, and a `jump` that
asks herdr to focus the main session of the house the top one belongs to, or of a named
repo or branch. It is the first thing in
Whiska that moves the person's screen, and only ever because the person asked in that
same breath; the record is read without the owl-alive guard, since a question already
recorded is waiting whether or not anything is awake (ADR-0043). Then the statusline split in two, one line per surface: the machine-wide one is
drawn once on herdr's tab bar, by a `tab_bar_right` command entry the person keeps in
their own herdr config running the `~/.whiska/herdr-status.sh` that `whiska owl install`
writes — the owl always, and what is waiting anywhere — with the doctor reading herdr's
config and printing the entry to paste; the repo-scoped one is back in Claude Code's
statusline and is now a board, written by `whiska init` and redrawn every 2 seconds: a row
per mouse of this repo — its branch, what its pane is doing, and either the question
waiting on the person or its last action, read from the mouse's own transcript. The house
renders it into `~/.whiska/board/` and the script prints that file, so the line starts
nothing and carries no owl (ADR-0051, ADR-0050, ADR-0048 and its amendment, ADR-0027,
ADR-0044).
Nothing in Whiska types into a session that is not its own house's main session any more
— a short-lived cross-house nudge did, as a user turn the other Claude could not tell
from a prompt, and ADR-0044 deleted it. Then the `CLAUDE.md` block, which is the other half of
the protocol coming home: `whiska init` writes the worktree decision tree, the
worktree-status marker and how a question reaches the person into the repo's own
`CLAUDE.md`, each in its own named markers so the next run replaces one part without
touching the others and a part marked `keep` is the person's for good (ADR-0045,
ADR-0017). It installs `spawn-worktree`, `send-to-worktree` and `drop-worktree` beside
the reading skills, so the skills that create a mouse ship with the thing that tracks it
(ADR-0046). Both used to live in one person's global `~/.claude/CLAUDE.md`, applying to
every repo whether Whiska was there or not. 863 tests.

**Designed, decided, not yet written.** The per-repo and global sockets (ADR-0024,
ADR-0025); `whiska stop` for one house (ADR-0003, needs the socket); push approval;
the machine-wide line reading the owl over the
global socket instead of the process table (ADR-0027); cross-repo commands. The doctor and the statusline find the
owl through the process table until the global socket exists.

## Regenerating

Written by hand from `CONTEXT.md`, `docs/adr/` and `lib/`, using the `c4-architecture`
skill. The rule for keeping them honest lives in `CLAUDE.md` — when an ADR or the
built/designed split changes, the affected diagram changes in the same piece of work.
