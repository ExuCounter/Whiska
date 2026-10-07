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
over by its question id alone. A brief is **buildable** once no **costly choice** in it is
left open, "done" and the failing test that proves it included; until then it gets
grilled, after the mouse has read the code and before it writes any (ADR-0063). A grilled
brief is buildable once its **spec** has the person's ok.
_Avoid_: task, ticket

**Grilling**:
The rounds of questions a mouse asks before building a brief that is not yet buildable:
every costly choice still open, each with the answer the mouse recommends, then a wait for
the person's ok. A round asks the whole frontier — every question whose prerequisites are
already settled — in one message, because each round costs the person a full round trip.
A truly trivial task — a typo, a rename, a one-line fix, with no costly choice in it — is
never grilled.
_Avoid_: interview, clarification

**Costly choice**:
A choice in a brief that has real alternatives and is costly to undo: something outside
the change depends on it — a file format, a command-line flag or interface, stored data, a
dependency added or dropped, behaviour the person would notice — or it touches secrets,
access or a security check, or the rest of the change is built on it. A mouse asks these
before building. Every other choice is **cheap**: the
mouse decides it and lists it in its final report (ADR-0063).
_Avoid_: big decision, one-way door

**Spec**:
A grilled brief, written down: its problem, user stories, decisions, testing and what is
out of scope, in `.whiska-spec.md` at the worktree root, which git ignores. The mouse
writes it with the `whiska-spec` skill after the last grilling round, sends it whole as a
question, and builds only on the person's ok. A brief that needed no grilling gets none;
a task's size never skips it. The person's words are that brief's spec
(ADR-0076).
_Avoid_: plan, design doc, ticket

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
closed the moment it is sent — it is never answered, and it waits for the delivery slot
but never holds it. A question is **open** while it waits to be told, **sent** once
delivered and waiting for its answer, then **answered** once `whiska reply` saved the
answer — which frees the slot whether or not the mouse has **taken** it yet; **superseded** when its own mouse asked a
newer one, **closed** by hand or as a `done` report once told, **settled** when its
mouse's branch landed and there is nothing left to answer to — the merge was the answer
(ADR-0064) — and **orphaned** when nothing can act on it and nothing ever answered it
(its mouse died, its worktree is gone, its record no longer stands for a worktree of this
house) with the work still not landed. An open question is **queued behind** the sent one while
another holds the slot, a `done` report included; the board, `whiska questions` and the
**inbox** say that — `finished · queued behind #n` for a report — and keep "waiting on
you" for the one actually sent (ADR-0051).
_Avoid_: report (as the table/record name — the word now names how a message reads,
see **Report**), event (as the table/record name)

**Report**:
The shape a mouse's final message takes — one line of what is true now, where it lives,
what changed with each cheap choice made without asking, what was verified rather than
assumed, one thing worth knowing, then
either nothing waiting or the one decision: a plain brief of the terms, the problem and
why there is a choice, then its options and a recommendation. It
names how a message reads, never the record it becomes: once collected the same message
is a **question**. A mouse's `report` part teaches it. `done` report is the older,
narrower use of the word — a question whose marker said `done` — and both stay.
_Avoid_: summary, status, update, hand-off

**Finish**:
What becomes of a branch once its mouse is done: landed on the current branch by
cherry-picking its own commits, oldest first, its merges from the base skipped
(ADR-0079; it was `merge --no-ff`), opened as a
merge request, carried on by its mouse, left alone to be talked to further, or dropped
unmerged. The person picks one when a "finished" question is told, from what fits the
branch as its **branch line** reads: files not committed are committed first, in the
mouse's worktree, then landed or opened as a request; a branch with nothing on it is
offered neither; and one git cannot read is offered all four. A repo may name its usual
choice, and that one is recommended where landing is. A **held** mouse's finished line is never told, so it is never
offered one. A **proposal** from a branch with nothing to merge — a sniff mouse's, or any
mouse's whose branch has nothing on it — is built by a fresh mouse, talked to
further, or dropped, and none is recommended. A finish is never an answer — a finished
question has nothing to answer — and it is only ever offered for a finished one.
_Avoid_: close (which a question does), disposition, land. **Cleanup** now names something
else — what becomes of the worktree after the branch has landed, not what becomes of the
branch

**Branch line**:
The line `whiska show` prints straight under a finished question's heading: what its
branch holds as git says when it is shown — its own commits beyond the base, its files
not committed, or `unknown`. Whiska's record of the branch, never the mouse's word, and
what a **finish** is chosen by (ADR-0074).
_Avoid_: model-and-branch line (the statusline's), branch status, status line

**Proposal**:
The block a finished investigation ends its report with when it changed nothing and found
something that should change: **Proposed build**, then a Found, a Build and a Touches
line. Content, never classification — the turn still ends on `done` — so it travels inside
the question's text, and the main session reads it the way it reads lettered options. It
is offered when the branch has nothing to merge, whatever the mouse's mode. Its lines are
the preview of the one question the person is asked, and building it starts a fresh
mouse shaped for that work rather than flipping the one shaped for the investigation
(ADR-0074).
_Avoid_: plan, recommendation, next steps, hand-off (a word **Report** already rejected)

**Waiting**:
Everything a house holds that still wants the person: its open and sent questions,
and the entries still sitting uncollected on its doorstep. A `done` report is waiting
until the person has been told, and a doorstep entry is waiting although no question
exists for it yet. It is a state of the house, not a status on a row: the statusline
and `whiska waiting` both ask exactly this, so the two cannot disagree about it. A house is quiet when nothing is waiting; there is no other
word for the state, and **Quiet** is that same word said of one mouse. A **held**
mouse's questions are listed by the **inbox** but are not waiting on the person — they
parked them — so neither status line counts them; a question waiting behind **away** or
a **focus** is.
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
carries what the person set aside — `away`, or `focus: <branch>` — and why nothing is
being delivered while delivery is gated (ADR-0058, spelled `gated:`); a **held** mouse's
row says `held` where herdr's status would go, and a question waiting behind away or a
focus says `waits: away` or `waits: focus on <branch>` where a queued one says `queued
behind #n`. Only a live
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
(ADR-0057, ADR-0064). Before the gate, the queue is judged against what the person set
aside (ADR-0079): nothing goes while they are
**away**, only the focused mouse's under a **focus**, never a **held** mouse's — and a
sent question of a held or unfocused mouse does not hold the slot. Oldest first, always.
While the gate holds — the session mid-turn, a
draft in its box, or no box on its screen — the queue is **gated**, and the board says so once the hold has lasted
ten seconds (ADR-0058). A finished line waits for the
slot like any question, so it never lands over one the person is reading, but it never
holds it: once the slot is free it goes ahead of whatever is queued and is closed as it
is typed. Several go one at a time, each line counting how many more finished are
behind it (ADR-0008, note of 2026-10-06).
What is typed is a one-line pointer with the id and no command; the full text is
`whiska questions <id>`, which the `whiska-delivered` skill runs when the line lands.
Delivery only ever types into the main session of the question's own house (ADR-0044);
the only other lines Whiska types go into a mouse's own pane — a **pickup** and a
**doorbell**. Every delivery raises a **hoot**.
_Avoid_: notify, ping, relay (the old bash mechanism), push

**Doorbell**:
The one fixed line typed into a mouse's pane when the person has answered it — "🔔 The
person answered your question #12; the answer is attached …" — and never the answer
itself (ADR-0080). Never a 🐱: that is a delivered line, and
the `whiska-delivered` skill every session lists fires on one. `whiska reply` rings it
once the answer is saved; the owl rings it again on the backstop while the answer is not
**taken**, at least 90 s apart and at most three times, only into an idle pane with an
empty prompt box, never a held mouse's, a landed branch's or the main session's. A
doorbell rung twice is harmless: the second finds nothing left to hand over.
_Avoid_: nudge (retired), ping, poke, inbox (the person's listing — see **Inbox**)

**Taken**:
An answer the mouse's own `UserPromptSubmit` hook has handed over: printed as context
into a prompt in that mouse's session and stamped `taken_at`, the proof it arrived. Any
prompt takes it, the doorbell or one the person types into the pane. An answer that is
`answered`, not taken, and its mouse's newest question is **chased** — the owl keeps
ringing for it. One still not taken 90 s after the owl's third ring is **not taken**: the
board row, `inbox` and `whiska questions` say so, it counts as waiting on the person, and
one hoot goes out — once the person is back, if they are **away** or focused elsewhere.
A dead mouse's or a landed branch's answer is never not taken: nobody can act on it. A mouse that asked a newer question has moved past the answer, so it is
never chased or handed over (ADR-0005).
_Avoid_: acknowledged, acked, read, received, handled (firstmate's word, for a file a
worker moves)

**Hoot**:
The desktop notification the owl raises as it delivers a question — one per delivered
question, sent in the same breath as the line so the two can never disagree (ADR-0062).
It carries the house, the mouse's branch, the verb and the id, in the line's own words,
because the line only reaches somebody already looking at the main session and the point
of leaving a question is that they are not. A question that is only collected, or gated,
or set aside by **away**, a **focus** or a **hold**, has not hooted yet. herdr is asked to show it, from the person's own `[ui.toast]` and
`[ui.sound]` settings, and says whether it drew anything; `request` is its sound when a
decision is waiting and `done` when a branch finished. When herdr says its popups are off
or nobody is attached, the same hoot is raised on the desktop with `terminal-notifier` or
`osascript` on macOS, or `notify-send` on Linux, instead (ADR-0071). A hoot that fails is swallowed —
delivery is the job and the hoot is a courtesy — so `whiska doctor` is where the person
asks, by sending a hoot of its own down the same path and reporting what showed it.
_Avoid_: toast, alert, desktop notification as a term of its own (it is herdr's word for
how a hoot is shown, not for the thing)

**Gated**:
What delivery is while the gate says no and something deliverable is queued behind it:
the main session mid-turn, a draft in its box, no prompt box on its screen at all
(ADR-0068), or no main session it can reach. The question stays open and first in the
queue, and the gate holds until it lets go — one hold however its reason changes. Said in
two places in the same word: the board's waiting line once it has lasted ten seconds
(ADR-0058, as ADR-0079 respells it), and
`whiska doctor` whenever it is asked. Being gated is never a question's own status; it is
what delivery is doing, or not doing, to the queue. While the person is **away** the gate
is beside the point, and the line says `away` instead.
_Avoid_: held (a mouse the person put on hold — see **Held**; this entry carried that word
until 2026-10-06), blocked (a mouse's herdr status), stuck (a mouse that is not
progressing), paused, queued (every question behind the first is that anyway)

**Away**:
The person's own word for "nothing reaches me": one setting for the whole machine, a file
under the whiska home that `away` writes and `resume` removes
(ADR-0079). While it is set nothing is delivered to
any main session, no hoot is raised, mice keep working, and `inbox` keeps listing what
they ask, with `away` on its first line. Said on herdr's tab bar — `🦉 watching · away` —
and on every repo's board. Not a question's status, and not the owl's state: the owl is
watching all the while.
_Avoid_: quiet (a house with nothing waiting, or a mouse with nothing left to do), do not
disturb, muted, paused, held (a mouse's), gated (the gate's)

**Focus**:
One repo's narrowing of delivery to one mouse: the focused mouse's `mouse_id` on the
house's own row, set with `focus <branch>` and cleared by `resume`
(ADR-0079). Only that mouse's questions reach the
repo's main session; the rest wait — still listed by `inbox` and `whiska questions` as
`waits: focus on <branch>`, still counted as waiting — and a question already delivered
from another mouse no longer holds the one slot against the focused one. Per repo because
a branch is one repo's; silencing other repos is what **away** is for. The board's
waiting line says `focus: <branch>`; the tab bar says nothing of it.
_Avoid_: pin, filter, mute (the others are not muted, they wait), focus as herdr's word
for bringing a pane into view (see **Jump**)

**Held**:
A mouse the person put on hold with `hold <branch>`: a `held_at` stamp on its record, a
real stored status, lifted by `resume <branch>` or by a reply to one of its questions
(ADR-0079). The hook refuses its next write or
shell command — a read passes until then, or until the turn ends — with a reason that
says to end the turn here and say where it stopped
(`Whiska.Rule.Held`); the message it ends on sits in the inbox marked `held`, never
delivered, and never counted as waiting on the person — they parked it. A held mouse is
never offered for landing, since its finished line is never told; never taken down by
cleanup (ADR-0061); never picked up (ADR-0067). Its row on the board and in `whiska mice`
says `held` where herdr's status would go. The word this entry took from the gate on
2026-10-06 — see **Gated**.
_Avoid_: parked, paused, stopped (a dead turn's and herdr's word), blocked (herdr's),
gated (the gate's), on ice

**Person's command**:
A `whiska` command only the person runs, never a mouse: `away`, `hold`, `focus`,
`resume`, `reply`, `dismiss` and `close` — the ones that set or end what reaches them,
which mouse stops, and what a mouse is told. The hook refuses a mouse's shell command that
is one of them, by its head word, `whiska` in front or bare (`Whiska.Rule.Persons`,
ADR-0079); a mouse that needs one says so in its
report. The reading commands — `inbox`, `show`, `questions`, `waiting`, `mice` — are
anyone's.
_Avoid_: admin command, privileged command (there is no privilege, only whose decision it
is), main-session command (the person may run one from any terminal)

**Inbox**:
The person's list of everything waiting on them across every repo on the machine —
`inbox`, the same reading as `whiska waiting` (see **Waiting**) — with a last column
saying why a row is not being delivered (`held`, `away`, `focus: <branch>`, `queued
behind #n` for one waiting on the question that is out, or `not taken` for an answer its
mouse has not **taken**) and a first
line when they are away. It is a listing, not a place: a question sits in a house, an
uncollected entry on a doorstep, and the inbox reads both. `show`, `reply` and `dismiss`
act on this repo's rows only; ids repeat across repos.
_Avoid_: queue (delivery's), backlog, doorstep (where an entry sits before it is a
question — see that entry), waiting list (**Waiting** is the state, this is the listing)

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
from then on (ADR-0026), never nudged again. A mouse with a **chased** answer is never
picked up: its next turn has not begun, and the **doorbell** carries it on. One of the two
lines the owl types anywhere but its own house's main session (ADR-0044, as ADR-0067 and
ADR-0080 amend it).
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
person answers from their own (ADR-0043). A separate move, `whiska open <id|branch>`,
takes the person to one named mouse's own pane when they ask for that mouse; it is not a
jump, and the owl never makes it either (ADR-0043's note of 2026-10-06).
_Avoid_: goto, focus (herdr's word for the mechanism of bringing a pane into view, and
since 2026-10-06 the person's word for narrowing delivery to one mouse — see **Focus**;
neither is a jump), switch, attach, take over

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
_Avoid_: research mode, research mouse (`research/` is the prefix a sniff mouse's branch
carries, not the mode's name)

**Owl**:
The one always-awake presence per machine, kept running by its **service manager**, that
keeps every project's house standing and is the only thing that can see across all of them
at once. Seeing is not acting: the owl reads every house, and types into none but the one
each question belongs to (see **Nudge**, retired) — and, since ADR-0067, into a mouse's
own pane when that mouse's turn died, once (see **Pickup**). Not per-project: a person has many
houses and exactly one owl.
_Avoid_: daemon, server, service

**Service manager**:
The operating system's own program that keeps the owl running: it starts it at login
and restarts it after a crash. launchd on macOS, through the user LaunchAgent
`com.whiska.owl`; systemd on Linux, through the user unit `whiska-owl.service`
(ADR-0040, ADR-0077). `whiska owl
install|stop|start|uninstall` drive whichever is in force, and mean the same on both.
Either runs the same wrapper, `~/.whiska/owl.sh`.
_Avoid_: supervisor (OTP's word, for the process tree inside the owl), service (the owl
itself is not one), daemon

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
machine-wide one is herdr's tab bar: the owl's state, always, whether the person is
**away**, and which whiskas have something waiting — `🦉 watching`,
`🦉 watching · away · 🐱 2 whiskas`, `🦉 owl down · 🐱 2 whiskas`. The repo-scoped one is
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
what a question sits on before it ever reaches that queue), larder, inbox (the person's
listing of everything waiting, which reads this among other things — see **Inbox**)

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

**Rules** (a session's):
The worktree protocol, in Whiska's words, as one session starts with it: the `SessionStart`
hook prints the **parts** its role needs and nothing else (ADR-0081).
Outside herdr, none. The main session gets `worktrees` (routing work to mice), `work` and
`delivery`; a mouse gets `work`, `marker`, `report` and `finish`. Said again after
`/compact`, `/clear` and a resume. Rules, not prose: an imperative or a concrete fact per
line, with the reasoning left in Whiska's own ADRs (ADR-0055). A part the person holds as
`keep` is left out, since their own wording is already in context — in `~/.claude/CLAUDE.md`
always, and in the project's `CLAUDE.md` only under that repo's own install.
_Avoid_: block (the older home of the same rules), prompt, instructions, system prompt

**Block**:
The region of a `CLAUDE.md` an older `whiska init` wrote the rules into, bounded by one
outer marker pair and made of **parts**. Nothing writes one now: `whiska init` and
`whiska uninstall` take it out, keeping a `keep` part and any text of the person's inside
the markers, and leaving everything outside them byte for byte (ADR-0081).
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
exits before doing anything — for every hook, `SessionStart` included — and Claude Code's
own rules settle the statusline and the skills (ADR-0056).
_Avoid_: level, mode (build and sniff are modes), profile, target

**Stands down**:
What the global install does in a repo that wires Whiska itself — not "is overridden",
which would suggest something still ran. The global shim exits before resolving anything,
so for that repo it is as though it were not installed. The reason it must: Claude Code
merges the hook arrays from both files, so a hook that did not stand down would deny
twice and leave the same question on the doorstep twice.
_Avoid_: override, shadow, disable, precedence

**Part**:
One named piece of a session's **rules** — `worktrees`, `work`, `delivery`, `marker`,
`report` and `finish` — each going to one role or both. The name is what `keep` claims: a
part whose start marker in a `CLAUDE.md` says `keep` is the person's, left out of what the
hook prints and left in place when an old **block** is taken out (ADR-0045,
ADR-0081). `scope` was a part of the global block only and is gone.
_Avoid_: block (the whole thing), fragment, chunk

**Worktree-status marker**:
The line a mouse ends every response with, and the only thing a turn is classified by
(ADR-0009). It is written in invisible separators (U+2063) so the person watching the
pane never sees it: three of them for `done`, two for `needs-decision`, whose readable
pointer sentence sits on the line above. `done` means the brief is done: a turn that stops
short of it on purpose — a failing test written first, a mid-task answer — ends on
`needs-decision`, its option A the next step. The older bracket spelling,
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
send reviewers over its own diff, go round once more, commit the work on its branch, and
only then write the marker.
Plain instructions in the `whiska-finish` skill `whiska init` installs, which a mouse's
`finish` part names as the trigger and nothing more — the steps only matter as a turn
ends, so they stay out of context until then (ADR-0055). Nothing changed since the
session's last green finish → the checks and reviewers are skipped and the message says
so. Run by the mouse itself: Whiska
neither runs it nor knows whether it was run (ADR-0049). What green means here, where the
decisions live and what a ticket id looks like are the repo's to say, under a `## Finish`
heading in its own `CLAUDE.md`. The same heading carries the person's
usual choice for a finished branch, the repo's extra **reviewers**, and a security scan
it would rather run than a reviewer.
_Avoid_: review loop (retired, below), checks, gate (the no-mistakes gate is a different
thing, and it runs after a push rather than at the end of a turn), CI, ralph loop

**Reviewer**:
One subagent sent over the change in finishing's third step, on one **axis** — correctness,
security, performance, frontend when a person can see the change, and tests when the change
touches a test file — plus any the repo names on its `reviewers:` line. The tests axis is
wio's `wio-test-reviewer` or nothing: where wio is not installed the message says so in one
line (ADR-0075). A reviewer **reports and never edits**, which is what
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
