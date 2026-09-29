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

**Mouse record**:
Whiska's own persisted row tracking a mouse — its pane, worktree path, branch label,
and mode — keyed by `mouse_id`. Outlives the mouse itself: a dead mouse still has a
mouse record, marked dead rather than deleted.
_Avoid_: Mouse (bare) when the distinction between the live session and the tracking
row actually matters

**mouse_id**:
The one stable identity for a mouse — an opaque id minted once and written to a hidden
marker file at the worktree's root when the mouse is created. Never the branch name or
folder path; both of those can change without the mouse_id changing.

**Question**:
A message a mouse sends when it finishes a turn. Most are real questions — they enter
the delivery queue and wait for an answer. A turn that ends with no marker at all is an
**unmarked** question: delivered like any other, recorded as having arrived unmarked. A
`done` report is delivered like any other too, told as "finished" with no reply offered,
and closed the moment it is sent — it is never answered and never holds the delivery
slot. A question is **open** while it waits in the queue, **sent** once delivered and
waiting for its answer, then **answered**; **superseded** when its own mouse asked a
newer one, **closed** by hand or as a `done` report once told, **orphaned** when nothing
can act on it (its mouse died, its worktree is gone).
_Avoid_: report, event (as the table/record name)

**Waiting**:
Everything a house holds that still wants the person: its open and sent questions,
and the entries still sitting uncollected on its doorstep. A `done` report is waiting
until the person has been told, and a doorstep entry is waiting although no question
exists for it yet. It is a state of the house, not a status on a row: the
statusline's elsewhere segment and `whiska waiting` both ask exactly this, so the two
cannot disagree about it. A house is quiet when nothing is waiting; there is no other
word for the state.
_Avoid_: pending, outstanding, open (a question's own status, which is narrower), the
queue (delivery's, which a doorstep entry has not reached)

**Main session**:
The one herdr pane per house that questions are delivered to — the person's own Claude
Code session in the main checkout, recorded by `whiska start` from the pane it is run in.
A house has at most one; nothing is delivered until one is recorded, and it is also where
a Jump lands.
_Avoid_: primary, parent, captain

**Delivery**:
The owl typing one question's line into the main session — only when that pane is idle
and no other question is already sent. A queue, not a batch: the next question goes when
the previous one is answered (or superseded, or closed — a `done` report closes itself on
sending) and the session is idle again.
What is typed is a one-line pointer with the id and no command; the full text is
`whiska questions <id>`, which the `whiska-delivered` skill runs when the line lands.
Delivery is the only thing Whiska types anywhere, and it only ever types into the main
session of the question's own house (ADR-0044).
_Avoid_: notify, ping, relay (the old bash mechanism), push

**Nudge** (retired):
A line the owl used to type into *another* house's idle main session, to force that
session's statusline to redraw. Removed on 2026-09-29 (ADR-0044): the line landed as a
user turn that Claude Code could not tell from a typed prompt, so it cost that session a
turn and the model improvised on it. Nothing in Whiska now types into a session that is
not its own house's main session. The elsewhere segment it existed to refresh is kept
current instead by the `refreshInterval` on the statusLine command, which re-runs the
statusline script every 15 seconds while the session sits idle.
_Avoid_: reviving the word for anything cross-house. (`specs/spec.md` uses "corrective
nudge" for a message into a *stuck mouse's own* pane — a different, still-unbuilt idea,
and the only sense the word is left with.)

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

**Build mode**:
A mouse mode that produces a real code change. Edits confined to its own worktree,
push needs approval.

**Sniff mode**:
A mouse mode for investigation only. Never writes code, never pushes — produces a
report instead.

**Owl**:
The one always-awake presence per machine, supervised by `launchd`, that keeps every
project's house standing and is the only thing that can see across all of them at
once. Seeing is not acting: the owl reads every house, and types into none but the one
each question belongs to (see **Nudge**, retired). Not per-project: a person has many
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

**Doorstep**:
Where a mouse leaves a question for the owl: a directory in the house, holding entries the
owl has not collected yet. A mouse always leaves its question here and never hands it over
directly, so whether the owl is awake changes nothing about what the mouse does.
_Avoid_: spool, outbox, queue (the delivery queue is a different thing — the doorstep is
what a question sits on before it ever reaches that queue), larder, inbox

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

**Review loop**:
The repo's own answer to "is this turn actually over?" — held by the repo, not by
Whiska, and consulted the moment a mouse tries to end a turn on `done`. It has two
things to say and no more: whether the repo's checks are green, and that the mouse has
not yet read its own diff back against the repo's written decisions. Either one sends
the mouse back to work; neither is ever Whiska's opinion, and Whiska never reads what
the loop is made of. It runs ahead of the doorstep rather than beside it, so a turn it
sends back leaves no question at all — not a question that is later corrected. Bounded by
construction: a loop that cannot be satisfied gives up and lets the person see the failure
instead.
_Avoid_: checks, gate (the no-mistakes gate is a different thing, and it runs after a
push rather than at the end of a turn), CI, ralph loop
