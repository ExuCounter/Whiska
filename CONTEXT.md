# Whiska

An Elixir/OTP coordinator that manages Claude Code worker sessions running in isolated
git worktrees, replacing this repo's bash-based worktree-notification relay.

## Language

**Whiska**:
The per-project coordinating presence a person controls directly — their main Claude
Code session for a project, backed by that project's own house in the shared owl. Counted
as one only while that house is open (in the open-houses record) and a live session sits
in the project's main checkout; a repo with a house on disk but no owl keeping it is not
a whiska, however live its session.
_Avoid_: instance, coordinator

**Mouse**:
A running herdr pane + Claude Code session working inside its own isolated git
worktree, spawned and supervised by a Whiska.
_Avoid_: worker, crewmate, agent

**Brief**:
What a mouse is given to build — the person's own words, routed in whole by
`spawn-worktree` or `send-to-worktree`, or a **proposal** the person said yes to, handed
over by its question id alone. A brief is **buildable** when the mouse can say
what "done" looks like and name the failing test that proves it without guessing anything
the person has an opinion on; one that is not gets grilled before any code (ADR-0063).
_Avoid_: task, ticket, spec

**Grilling**:
The rounds of questions a mouse asks before building an unbuildable brief: what "done"
looks like, which part of the app, what data, the edge cases. A round asks the whole
frontier — every question whose prerequisites are already settled — in one message,
because each round costs the person a full round trip.
_Avoid_: interview, clarification

**Mouse record**:
Whiska's own persisted row tracking a mouse — its pane, worktree path, branch label,
and shape — keyed by `mouse_id`. Outlives the mouse itself: a dead mouse still has a
mouse record, marked dead rather than deleted, and a mouse whose worktree has been cleaned
up is marked removed and left there, permanently inert. A record is **stale** when it no longer
stands for a worktree of this house — a record made later covers the same folder, or one
of the worktrees nested inside its folder. A stale record is nobody's mouse: it is never
matched to a pane, and neither `whiska mice` nor the board has a row for it. This sense
of **stale** is about a record standing for the wrong thing; the other sense, a process
running an older version of itself, is **running old** — see that entry.
_Avoid_: Mouse (bare) when the distinction between the live session and the tracking
row actually matters

**mouse_id**:
The one stable identity for a mouse — an opaque id minted once and written to a hidden
marker file at the worktree's root when the mouse is created. Never the branch name or
folder path; both of those can change without the mouse_id changing.

**Start directory**:
The directory a Claude Code session was started in, read from the first entry of its own
transcript. Which session a hook is firing in — which mouse, or none — is derived from
this and from the pane it runs in, and never from the working directory the hook is
handed: that one follows every `cd` the session runs, so a main session that stepped into
a worktree read as that branch's mouse and a mouse that stepped out read as nobody
(ADR-0053). A start directory under `worktrees/` that is no checkout of its own — the
ordinary folder a slashed branch nests under — is **nobody**: no mouse, no mode, no
marker (ADR-0030's note). It keeps containment all the same, and a write into the main
checkout from there is denied (ADR-0013).
_Avoid_: cwd, working directory (both name the thing that moves)

**Question**:
A message a mouse sends when it finishes a turn. Most are real questions — they enter
the delivery queue and wait for an answer. A turn that ends with no marker at all is an
**unmarked** question: delivered like any other, recorded as having arrived unmarked. A
`done` report is told as "finished" with a **finish** offered in place of a reply, and
closed the moment it is sent — it is never answered, and it neither waits for the
delivery slot nor holds it. A question is **open** while it waits to be told, **sent** once
delivered and waiting for its answer, then **answered**; **superseded** when its own mouse asked a
newer one, **closed** by hand or as a `done` report once told, **settled** when its
mouse's branch landed and there is nothing left to answer to — the merge was the answer
(ADR-0064) — and **orphaned** when nothing can act on it and nothing ever answered it
(its mouse died, its worktree is gone, its record no longer stands for a worktree of this
house) with the work still not landed. An open question is **queued behind** the sent one while
another holds the slot; the board and `whiska questions` say that, and keep "waiting on
you" for the one actually sent (ADR-0051).
_Avoid_: report (as the table/record name — the word now names how a message reads,
see **Report**), event (as the table/record name)

**Report**:
The shape a mouse's final message takes — one line of what is true now, where it lives,
what changed, what was verified rather than assumed, one thing worth knowing, then
either nothing waiting or the one decision with its options and a recommendation. It
names how a message reads, never the record it becomes: once collected the same message
is a **question**. The block's `report` part teaches it. `done` report is the older,
narrower use of the word — a question whose marker said `done` — and both stay.
_Avoid_: summary, status, update, hand-off

**Finish**:
What becomes of a branch once its mouse is done: merged into the current branch, opened
as a merge request, left alone to be talked to further, or dropped unmerged. The person
picks one when a "finished" question is told; a repo may name its usual choice, and that
one is recommended. A sniff mouse that ended on a **proposal** has nothing to merge, so
its finish is built by a fresh mouse, talked to further, or dropped — and none is
recommended. A finish is never an answer — a finished question has nothing to
answer — and it is only ever offered for a finished one.
_Avoid_: close (which a question does), disposition, land. **Cleanup** now names something
else — what becomes of the worktree after the branch has landed, not what becomes of the
branch

**Proposal**:
The block a finished investigation ends its report with when it changed nothing and found
something that should change: **Proposed build**, then a Found, a Build and a Touches
line. Content, never classification — the turn still ends on `done` — so it travels inside
the question's text, and the main session reads it the way it reads lettered options. Its
lines are the preview of the one question the person is asked, and building it starts a
fresh mouse shaped for that work rather than flipping the one shaped for the
investigation (ADR-next-a-finished-investigation-hands-off).
_Avoid_: plan, recommendation, next steps, hand-off (a word **Report** already rejected)

**Waiting**:
Everything a house holds that still wants the person: its open and sent questions,
and the entries still sitting uncollected on its doorstep. A `done` report is waiting
until the person has been told, and a doorstep entry is waiting although no question
exists for it yet. It is a state of the house, not a status on a row: the statusline
and `whiska waiting` both ask exactly this, so the two cannot disagree about it. A house is quiet when nothing is waiting; there is no other
word for the state, and **Quiet** is that same word said of one mouse.
_Avoid_: pending, outstanding, open (a question's own status, which is narrower), the
queue (delivery's, which a doorstep entry has not reached)

**Board**:
What every mouse of one house is doing, a row each, drawn where the person is already
looking: this repo's Claude Code statusline. A row is the mouse's branch, what herdr says
its pane is doing, and one thing more — the question waiting on the person when there is
one, otherwise the mouse's **topic**, and otherwise its **last action**. A row also says
how long its mouse has been going, in the same words `whiska mice` uses for uptime —
`45s`, `6m`, `1h 33m`. Three things on a row are coloured, in plain ANSI the person's own
terminal theme shades: the branch cyan, a question waiting on them yellow, the elapsed
time dim. Colour never carries meaning on its own — every row says in words what its
colour says. The topic is the
short human summary of what the mouse is working on, "Order builder for distributors",
read from herdr's pane list where Claude Code keeps it as the pane's title. The last
action is the tool call it is in the middle of or the last thing it said, read from its
own Claude Code transcript and never asked for (ADR-0050); it takes the column back when
the mouse is blocked, or working and silent for two minutes, which is when what it is
stuck in says more than what it set out to do. Five rows, unless more mice than that are
waiting: a mouse with a question on the person is never one of the ones left off. It is
kept current for the person rather than asked for. A working mouse's row carries a
**ticker**, a dot growing to three and starting over, one frame per redraw: on a row that
says a mouse is busy, a still board and a frozen one look the same, and the ticker is the
difference. Only a working row ticks; an idle mouse, a blocked one, one waiting on the
person and one herdr cannot account for are all still, because on those rows nothing is
meant to be moving. `whiska watch` is the same rows, worked out on the spot and printed
once — and with no ticker, since nothing is refreshing behind them. The `waiting` line
carries why nothing is being delivered while delivery is held (ADR-0058). Only a live
mouse is a row: a dead one has none, and what it left behind unanswered is counted on an
`orphaned` line of its own, under the `waiting` one — nobody can answer an orphan, so it
is never counted as waiting. A question its mouse's branch landed on is **settled**
rather than orphaned, and is counted on neither line: an orphan means something went
wrong, not that a branch merged (ADR-0064). That line names the branches the orphans came off, and an orphan whose record
kept no branch is named by its own question id. Above the rows, and only when it is true,
one line says that this pane is not the one this repo's questions are delivered to
(ADR-0065). It is the one thing on the board that differs between two sessions reading
it, drawn by the statusline script from the pane the owl wrote down beside the board; a
mouse never sees it, because a mouse draws no board. The board only reports — nothing on it acts (ADR-0051).
_Avoid_: dashboard, monitor, status (the line the tab bar draws, which is not this), the
statusline (the surface, not what is drawn on it), title (herdr's and Claude Code's word
for where the topic is read from, not for what the board says)

**Main session**:
The one herdr pane per house that questions are delivered to — the person's own Claude
Code session in the main checkout, recorded by `whiska start` from the pane it is run in —
which also starts Claude Code there when nothing is running in that pane yet (ADR-0066).
A house has at most one; nothing is delivered until one is recorded, and it is also where
a Jump lands. Every other session in the main checkout is told it is not the one, on the
board (ADR-0065); a session cannot be asked which it is, so it is never guessed at from
anything but the recorded pane.
_Avoid_: primary, parent, captain

**Delivery**:
The owl typing one question's line into the main session — only when that pane is idle
and no other question is already sent. A queue, not a batch: the next question goes when
the previous one is answered (or superseded, or closed, or orphaned, when its own mouse
dies while holding the slot) and the session is idle again. Nothing that cannot be
answered ever holds the slot: before each attempt, everything still waiting for a mouse
that is dead, or for a record that no longer stands for a worktree of this house, is
released — **settled** where its mouse's branch landed, **orphaned** where it did not
(ADR-0057, ADR-0064). While the gate holds — the session mid-turn, a
draft in its box, or no box on its screen — the queue is **held**, and the board says so once the hold has lasted
ten seconds (ADR-0058). A finished line is outside
the queue: nothing is waiting on the person in it, so it goes ahead of whatever is
waiting, takes no slot, and is closed as it is typed.
What is typed is a one-line pointer with the id and no command; the full text is
`whiska questions <id>`, which the `whiska-delivered` skill runs when the line lands.
Delivery is the only thing Whiska types anywhere, and it only ever types into the main
session of the question's own house (ADR-0044). Every delivery raises a **hoot**.
_Avoid_: notify, ping, relay (the old bash mechanism), push

**Hoot**:
The desktop notification the owl raises as it delivers a question — one per delivered
question, sent in the same breath as the line so the two can never disagree (ADR-0062).
It carries the house, the mouse's branch, the verb and the id, in the line's own words,
because the line only reaches somebody already looking at the main session and the point
of leaving a question is that they are not. A question that is only collected, or held,
has not hooted yet. herdr is asked to show it, from the person's own `[ui.toast]` and
`[ui.sound]` settings, and says whether it drew anything; `request` is its sound when a
decision is waiting and `done` when a branch finished. When herdr says its popups are off
or nobody is attached, the same hoot is raised on the desktop with `terminal-notifier` or
`osascript` instead (ADR-0071). A hoot that fails is swallowed —
delivery is the job and the hoot is a courtesy — so `whiska doctor` is where the person
asks, by sending a hoot of its own down the same path and reporting what showed it.
_Avoid_: toast, alert, desktop notification as a term of its own (it is herdr's word for
how a hoot is shown, not for the thing)

**Held**:
What delivery is while the gate says no and something is queued behind it: the main
session mid-turn, a draft in its box, no prompt box on its screen at all (ADR-0068), or
no main session it can reach. The question stays
open and first in the queue, and the hold lasts until the gate lets go — one hold however
its reason changes. Said in two places in the same word: the board's waiting line once it
has lasted ten seconds (ADR-0058), and `whiska doctor` whenever it is asked. Being held is
never a question's own status; it is what delivery is doing, or not doing, to the queue.
_Avoid_: blocked (a mouse's herdr status), stuck (a mouse that is not progressing),
paused, queued (every question behind the first is that anyway)

**Unplaced**:
A directory under a house's `worktrees/` container that is no checkout of its own — the
ordinary folder a slashed branch nests under, or a worktree laid out by hand. It is
**nobody**: no mouse, no `mouse_id`, no mode, and nothing it leaves is a question. It is
not nowhere, though — the main checkout is still above it, and a session sitting there is
denied a write into it exactly as a mouse would be (ADR-0013). Reading such a folder as a
mouse is what minted a mouse called `quality` for `quality/QUAL-350-lnkd-emails` and let
its question wedge a queue (ADR-0030's note, ADR-0057).
_Avoid_: phantom mouse (it is no mouse), ghost, orphan (a question's status), the
container (the `worktrees/` folder itself, which is not this)

**Draft**:
Whatever the person has half-typed in the main session's prompt box and not yet sent. A
draft *holds* delivery — the question stays open and first in the queue — however idle
herdr says the pane is (ADR-0047): idle is the model's word, and a line typed into an
occupied box lands inside the draft or submits it. The box is the lowest **frame** on the
screen — a pair of horizontal rules at column 0 — that holds a prompt line, and the whole
of it is read, not its first line. Neither half finds it alone: the marker `❯` is also how
Claude Code redraws the person's past messages and how a picker marks its highlighted row,
and a stray rule under the box would frame the status lines (ADR-0068). A screen with **no box on it**
holds too, and for a different reason — not a draft, but nowhere for the line to land,
which is what a dialog waiting on the person looks like. A frame Whiska cannot read is no
draft, and delivers. `whiska doctor` has a line of its own for the box, because a Claude
Code that changes how it draws one would otherwise show up only as every mouse going
quiet; a pane the person has scrolled up in is reported there, not warned about.
_Avoid_: input, buffer, typing state, pending prompt

**Dead turn**:
A turn that ended without reaching the doorstep. The session did not crash — it is
sitting there idle, holding its whole context, with an error on the screen — so from
outside it looks exactly like a mouse quietly working. Read from what Whiska already
owns: the mouse was seen working, its pane has gone quiet, and nothing of its has been
collected or is waiting on the doorstep (ADR-0067). A session idle before it was ever
prompted has not had a turn die; it has not had a turn.
_Avoid_: crash (nothing crashed), hang, timeout, failed turn (it may have done most of
its work)

**Pickup**:
The owl typing one short line into a mouse's own pane to carry a dead turn on — the
"corrective nudge" the Nudge entry below left the word with. Never the original prompt:
the session still knows what it did, and re-asking risks redoing a file already written.
One per dead turn, and a branch whose picked-up turn dies as well is a **stuck** mouse
from then on (ADR-0026), never nudged again. The one thing the owl types anywhere but
its own house's main session (ADR-0044, as ADR-0067 amends it).
_Avoid_: retry, resend, restart, relaunch (ADR-0026's rung four, a different act)

**Nudge** (retired):
A line the owl used to type into *another* house's idle main session, to force that
session's statusline to redraw. Removed on 2026-09-29 (ADR-0044): the line landed as a
user turn that Claude Code could not tell from a typed prompt, so it cost that session a
turn and the model improvised on it. Nothing in Whiska now types into a session that is
not its own house's main session. The elsewhere segment it existed to refresh is gone
too (ADR-0048): the statusline is machine-wide now, so there is no elsewhere.
_Avoid_: reviving the word for anything cross-house. The one sense it keeps is the
"corrective nudge" into a *stuck mouse's own* pane, which is built and is called a
**Pickup** above (ADR-0067).

**Jump**:
Moving the person to a whiska — Whiska asking herdr to bring a house's main session into
view, so the person is sitting where they can act on what is waiting rather than looking
at a pointer to it. The one thing Whiska does to the person rather than to a mouse, and
only ever because the person asked for it in the same breath: a typed command, or a
hotkey they bound. The owl never jumps, and since the Nudge was retired it makes no
cross-house move at all. The destination is the house's main
session, never a mouse's own pane: a mouse's pane is the mouse's workplace, and the
person answers from their own (ADR-0043).
_Avoid_: goto, focus (herdr's word for the mechanism, not for what this is), switch,
attach, take over

**Shape**:
What a mouse is spawned as: its mode, the model it runs on and the effort it runs at,
each chosen on its own — a hard investigation is sniff on the heaviest model at the
highest effort. Given by the spawn, with `whiska shape`, before Claude starts, so the
mouse's first tool call is already judged by its mode. The spawning session picks the
model and the effort by the ordered rules in `priv/models.json`; one it leaves unnamed
is the last rule's. The record also keeps the model the mouse actually ran on, read from
its transcript. There is no default mode: a mouse **never shaped** may read but not
write until the person runs `whiska mode` in its worktree. `whiska mode` moves the mode
and nothing else, so the record also keeps what the mouse was **shaped as** — the mode its
model and effort were chosen with — and a mouse moved off it says so, in `whiska mice`
and in the line `whiska mode` prints.
_Avoid_: profile, preset, role

**Build mode**:
A mouse mode that produces a real code change. Edits confined to its own worktree,
push needs approval.

**Sniff mode**:
A mouse mode for investigation only. Never writes code, never pushes — produces a
report instead. Says nothing about the model or the effort: those are chosen apart.

**Owl**:
The one always-awake presence per machine, supervised by `launchd`, that keeps every
project's house standing and is the only thing that can see across all of them at
once. Seeing is not acting: the owl reads every house, and types into none but the one
each question belongs to (see **Nudge**, retired) — and, since ADR-0067, into a mouse's
own pane when that mouse's turn died, once (see **Pickup**). Not per-project: a person has many
houses and exactly one owl.
_Avoid_: daemon, server, service

**House**:
One project's permanent home — its own database, its own mouse records, its own
identity — isolated from every other project's. A house exists from the first
`whiska start` in a repo onwards; it is never destroyed by stopping.
_Avoid_: subtree (means a git subtree and an OTP supervision subtree — both wrong
here), slice, partition

**Open house / shut house**:
Whether the owl is currently keeping a house's lights on. `whiska start` opens a house —
its socket starts listening, it subscribes to herdr, collection begins, and it gets its own
supervision inside the owl. `whiska stop` shuts it: socket closed, collection stopped,
supervision dropped. The house itself, its database and its mouse records, is untouched
either way.
_Avoid_: creating/destroying, starting/tearing down a house (those describe the house,
not its lights)

**Open-houses record**:
The owl's note to itself of which houses it has open, kept outside any one house: a
house is added when opened, removed when shut, and the note is left alone when the whole
owl stops, so the next `whiska owl` reopens the same houses. Anyone else — the
statusline, the doctor — trusts it only while an owl is running. It says nothing about
whether a house exists; that is the house's own affair.
_Avoid_: registry, manifest, house list (it lists open houses, not houses)

**Statusline**:
A line Whiska draws for the person. There are two, one per surface (ADR-0048). The
machine-wide one is herdr's tab bar: the owl's state, always, and which whiskas have
something waiting — `🦉 watching`, `🦉 owl down · 🐱 2 whiskas`. The repo-scoped one is
Claude Code's own statusline in that repo, appended to the person's global line: what is
waiting in this house and how many mice are alive here — `🐱 feat-auth · 🐭 2 mice`,
and nothing at all when the repo is quiet. No owl on it; that fact is machine-wide and
has one home.
_Avoid_: status bar, status line as two words (see **Worktree-status marker**), segment
(one part of it, not the line), tab bar (herdr's surface, one of the two places a
statusline is drawn, not a name for the line itself)

**Doorstep**:
Where a mouse leaves a question for the owl: a directory in the house, holding entries the
owl has not collected yet. A mouse always leaves its question here and never hands it over
directly, so whether the owl is awake changes nothing about what the mouse does.
_Avoid_: spool, outbox, queue (the delivery queue is a different thing — the doorstep is
what a question sits on before it ever reaches that queue), larder, inbox

**In flight**:
Said of a background subagent a mouse launched and has not been handed the report of.
Claude Code ends the mouse's turn while one is out and wakes the session when it reports,
so the `Stop` hook fires on a turn that is not over: with anything in flight it writes
nothing at all, and the doorstep never hears about it (ADR-0052). Read from the mouse's
own transcript, and structurally: a `tool_result` answering an `Agent` call gives the id,
the hand-back that clears it is stamped on the entry, and a turn the person typed clears
whatever was out. Never read from what the mouse said.
_Avoid_: running, pending, busy, mid-turn (all of them describe the mouse, and it is the
subagent that is out)

**Cleanup**:
Taking a landed worktree down: the worktree removed, the mouse's pane closed with it, the
branch deleted, and the mouse record stamped removed — unattended, by the owl, on its
backstop (ADR-0061). It happens only to a **quiet** mouse whose branch has landed: the
branch merged into the base, the worktree clean, nothing on it unpushed. Nothing is ever
forced, and anything that cannot be established leaves the worktree exactly where it is.
The mouse record survives, as every record does (ADR-0007); only the folder, the pane and
the branch go.
_Avoid_: teardown, reaping, archiving, drop (`drop-worktree` is the person's own way to
take a worktree down, which stays)

**Quiet**:
Said of a house with nothing waiting, and of a mouse with nothing left to do — the same
word, one subject down. A quiet mouse has nothing of its open or sent, nothing of its
left uncollected on the doorstep, its last word a `done` report, and no pane working in
its worktree — read from herdr's own pane list, by where each pane sits, never from the
mouse record's remembered pane. A mouse with no pane at all is quiet too: that is ADR-0026's dead
mouse. It is what cleanup waits for, and it is deliberately stricter than "nobody is
waiting on it": a mouse that never said it finished is never cleaned up after.
_Avoid_: idle (herdr's word for a pane, which is one of the four things this reads),
finished (a mouse's own claim; **Finishing** is the pipeline it runs), done (the marker)

**Running old**:
A process that is up but is serving a version older than the one on disk: the owl started
before the binary it runs was reinstalled, the installed binary built before the checkout
changed, or a Claude Code session still holding the hooks and settings it read at startup.
It is not down, so nothing fails — the change simply has no effect, and the person reads
the old behaviour as a bug in the new work. `whiska doctor` names each case against the
thing it is old relative to, and says the restart that fixes it. Distinct from a **stale**
mouse record, which is a row standing for the wrong worktree rather than an old version.
_Avoid_: stale (taken, and it means a record here), outdated, drift, out of sync

**Collection**:
The owl taking what a mouse left on the doorstep. Overwhelmingly event-driven — herdr
reports a mouse has gone idle and the owl collects that house then — with a slow timer only
as a backstop. Collection reads and marks; it never deletes and never touches the worktree.
_Avoid_: sweep (it implies tidying up, which is precisely what this must not do), poll,
drain, scan

**Backstop**:
The slow timer that collects a house's doorstep when nothing else has. It is a last
resort, never a working trigger: anything it finds is something the owl should already
have been told about, so it says so rather than quietly making up the difference. How
much it has had to collect is the measure of whether the event-driven path is alive.
_Avoid_: fallback, poller, sweep, safety net (all of them suggest a path that is fine to
be on; being on this one is the symptom)

**Block**:
The region of a `CLAUDE.md` that `whiska init` writes and re-writes — the worktree
protocol, in Whiska's words, travelling with the repo the way the hooks do. It is bounded
by one outer marker pair, and everything outside that pair is the person's and is never
read. Made of **parts**. Rules, not prose: an imperative or a concrete fact per line, with
the reasoning left in Whiska's own ADRs, which the file it is written into does not have
(ADR-0055). Written into the project's own `CLAUDE.md`, or into `~/.claude/CLAUDE.md` —
see **Scope**.
_Avoid_: section (a part is a section too, so the word cannot tell the two apart),
template, preamble

**Scope**:
Which root an install hangs off: the project (`whiska init`) or the person's home
(`whiska init --global`). Every path is the same relative path either way —
`.claude/hooks/whiska.sh` is one file in two places — so a scope is a root and nothing
else, and the merge, the `keep` semantics and the idempotency are one implementation for
both. Per-repo is the default and the only one that travels to someone else's machine
(ADR-0016); global is for a repo that will not carry a committed `.claude/`. Where a repo
has both, the project's copy is **in force** and the global one **stands down**: its shim
exits before doing anything, its block says so in its own header, and Claude Code's own
rules settle the statusline and the skills (ADR-0056).
_Avoid_: level, mode (build and sniff are modes), profile, target

**Stands down**:
What the global install does in a repo that wires Whiska itself — not "is overridden",
which would suggest something still ran. The global shim exits before resolving anything,
so for that repo it is as though it were not installed. The reason it must: Claude Code
merges the hook arrays from both files, so a hook that did not stand down would deny
twice and leave the same question on the doorstep twice.
_Avoid_: override, shadow, disable, precedence

**Part**:
One separately-replaceable piece of the block, in its own named markers —
`worktrees`, `marker`, `delivery`, `report`, `finish` today, and `scope` in the global
block only (ADR-0056). A part a scope does not ship is one that scope never adds and
never rewrites. A part is replaced where it stands
on the next `whiska init`, added if its markers are missing, and left exactly alone if
its start marker says `keep`, which is how a person claims one as their own or drops
it for good (ADR-0045). A part Whiska no longer ships stays where it is rather than
being tidied away.
_Avoid_: block (the whole thing), fragment, chunk

**Worktree-status marker**:
The line a mouse ends every response with, and the only thing a turn is classified by
(ADR-0009). It is written in invisible separators (U+2063) so the person watching the
pane never sees it: three of them for `done`, two for `needs-decision`, whose readable
pointer sentence sits on the line above. The older bracket spelling,
`[worktree-status: done]`, is still read and no longer written. The main session never
writes one. Distinct from the **marker file** that
carries a `mouse_id`: that one is identity on disk, this one is a line in a message.
Say which when either could be meant.
_Avoid_: status line (the statusline is a different thing entirely), tag, signal

**Pointer**:
One line standing in for a whole message, in two related places. A mouse's pointer is
the readable sentence it leaves beside its marker — the short question itself, or "3
questions ready, see above" — which sits on the line above a `needs-decision` marker; a
finished turn leaves none. The owl's delivery line quotes that sentence, and is itself a
pointer to the question the person reads in full with `whiska questions <id>`. Say
*the mouse's pointer* or *the delivery line* when both are in play.
_Avoid_: summary, title, subject, preview

**Finishing**:
What a mouse does before it is allowed to say `done`: read the work back against the
brief and the repo's written decisions, run the repo's checks and fix what they catch,
send reviewers over its own diff, go round once more, and only then write the marker.
Plain instructions in the `whiska-finish` skill `whiska init` installs, which the block's
`finish` part names as the trigger and nothing more — the steps only matter as a turn
ends, so they stay out of context until then (ADR-0055). Run by the mouse itself: Whiska
neither runs it nor knows whether it was run (ADR-0049). What green means here, where the
decisions live and what a ticket id looks like are the repo's to say, under a `## Finish`
heading in its own `CLAUDE.md` outside the block. The same heading carries the person's
usual choice for a finished branch, the repo's extra **reviewers**, and a security scan
it would rather run than a reviewer.
_Avoid_: review loop (retired, below), checks, gate (the no-mistakes gate is a different
thing, and it runs after a push rather than at the end of a turn), CI, ralph loop

**Reviewer**:
One subagent sent over the change in finishing's third step, on one **axis** — correctness,
security, performance, and frontend when a person can see the change — plus any the repo
names on its `reviewers:` line. A reviewer **reports and never edits**, which is what
separates it from an agent that merely reads code well: one that changes code, or whose own
description says not to dispatch it directly, is not a reviewer however good it is.
Whiska writes none of them. Wherever the session already lists an agent built for an axis
that one is sent, and where it lists none the mouse writes the prompt — the ordinary case,
not a degraded one (ADR-0054).
_Avoid_: critic, auditor, linter, checker (a check is step 2 and a different thing), gate

**Important / nit / pre-existing**:
The three words a reviewer's finding gets once it has survived being disproved, and the
word is what happens to it: fix it now; fix it if it is cheap; name it in the message and
leave it alone. Taken from the band names Anthropic's own reviewer already scores with,
rather than spelled a fourth way here (ADR-0054). None of the three reaches the person as
a decision: what a review can lead to is a wrong scope, a recorded decision the repo's
rules do not say how to change, or a second round still red, and all three were already
finishing's. Finishing escalates three further things that are not findings — an
untrusted ticket, an untrusted check command, and an agent definition it will not
dispatch — and those are untouched by this.
_Avoid_: blocking, critical, major/minor, P0, severity (the ladder is what to do, not how
bad it is)

**Review loop** (retired):
`.claude/hooks/review-loop.sh`, a `Stop` hook the repo owned, which blocked a turn ending
on `done` until a single `CHECK` command passed and the mouse had read its own diff back
once. Superseded by **Finishing** (ADR-0049): one check command could not know what green
means in a given repo, and a shell script could make no judgment at all. Nothing writes
it, chains it or runs it. A file still on disk is inert, `whiska doctor` says so, and
Whiska never deletes it (ADR-0007). Named here because repos still have the file and the
word is still in old handoffs; do not reach for it for anything current.
