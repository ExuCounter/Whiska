# Architecture

C4 diagrams for Whiska. `CONTEXT.md` is still the glossary and `docs/adr/` is still the
authority — these are a view onto both, not a third source of truth. Where a diagram and
an ADR disagree, the ADR wins.

| Level | File | Shows |
|---|---|---|
| 1 | [c4-context.md](c4-context.md) | Whiska between the person, Claude Code, herdr, git and launchd |
| 2 | [c4-containers.md](c4-containers.md) | Built against designed, as two boundaries |
| 3 | [c4-components-cli.md](c4-components-cli.md) | Inside the escript — hooks, init and the CLAUDE.md block, mode and shape, questions, the statusline, doctor, the delivery-side commands, waiting and jump |
| 3 | [c4-components-owl.md](c4-components-owl.md) | Inside the owl — houses, herdr, doorstep, classification, delivery |
| — | [c4-dynamic-pretooluse.md](c4-dynamic-pretooluse.md) | One tool-call decision, end to end |
| — | [c4-dynamic-question-delivery.md](c4-dynamic-question-delivery.md) | A question from the doorstep to its answer |

**Built.** v0.0.1's plumbing — mouse identity as a marker file, a per-repo SQLite house,
worktree containment and sniff mode enforced through `PreToolUse` (ADR-0030) — reachable
since a spawn shapes each mouse, mode and model, before Claude starts (ADR-0069). Then the
owl slice: the owl supervisor with one independently supervised house per project, each
house's herdr subscription and pane discovery, the doorstep and the `Stop` hook that
writes to it, collection on idle, and dead-mouse marking (ADR-0001, ADR-0036, ADR-0026).
Then delivery: `whiska start` recording the main session and starting Claude in its pane (ADR-0066), the idle-gated queue that types
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
statusline and is now a board, written by `whiska init` and redrawn every second: a row
per mouse of this repo — its branch, what its pane is doing, how long it has been going,
and one column more: the question waiting on the person, else the mouse's topic from
herdr's pane list, else what it is stuck in, read from the mouse's own transcript. The
branch, a waiting question and the elapsed time are coloured in plain ANSI the person's
own terminal theme shades, and nothing is said in colour alone. The house
renders it into `~/.whiska/board/` and the script prints that file, so the line starts
nothing and carries no owl — and above the rows, only when it is true, the script says
that this pane is not the one this repo's questions are delivered to (ADR-0051, ADR-0050,
ADR-0048 and its amendment, ADR-0027, ADR-0044, ADR-0065). Then the `Stop` hook reading the turn before it records it: the finish pipeline
sends its reviewers off as background subagents and Claude Code ends the mouse's turn
while they run, so the hook reads the tail of the transcript it is handed and writes
nothing at all while an agent it launched has not handed its report back — every one of
those endings used to arrive as an unmarked question that asked nothing (ADR-0052).
Nothing in Whiska types into a session that is not its own house's main session any more
— a short-lived cross-house nudge did, as a user turn the other Claude could not tell
from a prompt, and ADR-0044 deleted it. Then the `CLAUDE.md` block, which is the other half of
the protocol coming home: `whiska init` writes the worktree decision tree, the
worktree-status marker and how a question reaches the person into the repo's own
`CLAUDE.md`, each in its own named markers so the next run replaces one part without
touching the others and a part marked `keep` is the person's for good (ADR-0045,
ADR-0017). It installs `spawn-worktree`, `send-to-worktree` and `drop-worktree` beside
the reading skills, so the skills that create a mouse ship with the thing that tracks it
(ADR-0046), and `whiska-finish`, which carries ADR-0049's finishing pipeline out of the
block and into a skill the session loads only as a turn ends (ADR-0055), and `grilling`
and `whiska-spec`, the two skills a mouse runs before it builds: its questions, then the
spec the person approves, kept out of git at the worktree root
(ADR-next-a-grilled-brief-is-written-down-before-it-is-built). Both used to live in one person's global `~/.claude/CLAUDE.md`, applying to
every repo whether Whiska was there or not. A session is identified by where it started
and which herdr pane it runs in, never by where its shell currently stands, so the
person's own main session can step into a worktree without being mistaken for the mouse
that lives there (ADR-0053, `Whiska.Session`). Then the delivery slot's own guarantee:
nothing that cannot be answered ever holds it, so every attempt first releases what is
still waiting for a dead mouse or for a record that no longer stands for a worktree
(ADR-0057), and a hold the person cannot otherwise see — their session mid-turn, a draft
in its box, or no prompt box on the screen at all — is said on the board's waiting line
once it has lasted ten seconds (ADR-0058, ADR-0068). The statusline script `whiska init` writes now carries a version stamp, and
`whiska doctor` reads a repo's copy and says an upgrade is available rather than
rewriting a committed file (ADR-0059). And the phantom those first two were chasing is
gone: a folder under `worktrees/` that is no checkout of its own is no worktree, so
nothing mints a mouse for the directory a slashed branch nests under — while a session
sitting there is still denied a write into the main checkout, because losing identity
must not mean losing containment (ADR-0030's note, ADR-0013).
Then cleanup, which is the first thing in
Whiska that deletes anything: on the same 60 s backstop, a mouse whose branch has landed
has its worktree removed, its pane closed with it and its branch deleted, and its record
stamped removed rather than dropped. All four preconditions are local — merged into the
base, clean, nothing unpushed, and the mouse quiet (its last word a `done` report, nothing
of its waiting on the person, nothing of its uncollected, and herdr not calling its pane
working, read from herdr's own pane list by where each pane sits rather than from the
record's remembered pane) — so herdr is asked nothing until something has passed the local
checks, and then only for what is sitting in the worktree and which workspace to remove,
with `force: false`. Unknown is
never permission: a detached head, an unnameable base, a silent herdr or a live pane whose
workspace herdr does not name all leave the worktree standing (ADR-0061, superseding
ADR-0007's worktree half). The same sweep notes, for every mouse rather than only the ones
it may tear down, that its branch has landed, which is what settles a question that mouse
left waiting rather than orphaning it once there is nobody left to answer to — an orphan
now means abandoned work or a record that never stood for a worktree, not an ordinary
merge (ADR-0064). And delivery now reaches the person wherever they are: every
question it types raises one desktop notification in the same breath, carrying the house,
the branch, the verb and the id, with herdr showing it — or the desktop's own notifier when
herdr's popups are off or nobody is attached (ADR-0071) — and
`whiska doctor` probing with a hoot of its own to say whether one is seen (ADR-0062). And a turn that died is picked up:
a mouse seen working whose pane has gone quiet with nothing of its collected and nothing of
its on the doorstep had a turn that ended without finishing, so the owl types one short
continue into that mouse's own pane — never the original prompt, which would risk redoing
work already on disk. Once per dead turn: a branch whose picked-up turn dies as well is
ADR-0026's stuck mouse from then on. A pane has to have been quiet for two minutes across
separate sweeps first, and a herdr that will not answer throws every clock away, so a
laptop waking is not read as a whole fleet dying. It is the one thing Whiska types into a
session that is not its house's main one, which is the single exception ADR-0067 amends
into ADR-0044. 1377 tests.

**Designed, decided, not yet written.** Watching a branch after its mouse's last message:
the mouse pushes and opens the merge request with `gh` or `glab`, the owl reads status only
— one `curl` per branch on the existing backstop, a read-only token per forge, a GitHub and
a GitLab adapter behind one port — and a red build goes to the live mouse that owns the
branch, or to the person when that mouse is dead. Unknown is never a question. It would be
the owl's first outbound network call of any kind, and it still needs ADR-0044 opened for
it: ADR-0067's exception is a mouse's own dead turn and deliberately nothing wider, so a
build result typed at a live mouse is its own decision. It chains onto cleanup rather
than being part of it: green, then merged, then the worktree goes (ADR-0060, superseding
ADR-0032). Then the per-repo and global sockets (ADR-0024,
ADR-0025); `whiska stop` for one house (ADR-0003, needs the socket); push approval;
the machine-wide line reading the owl over the
global socket instead of the process table (ADR-0027); cross-repo commands. The doctor and the statusline find the
owl through the process table until the global socket exists.

## Regenerating

Written by hand from `CONTEXT.md`, `docs/adr/` and `lib/`, using the `c4-architecture`
skill. The rule for keeping them honest lives in `CLAUDE.md` — when an ADR or the
built/designed split changes, the affected diagram changes in the same piece of work.
