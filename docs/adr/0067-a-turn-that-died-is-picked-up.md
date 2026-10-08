# A turn that died is picked up, once, by the owl

A mouse that was seen working, whose pane has gone quiet, with nothing of its collected
and nothing of its on the doorstep, had a turn that ended without finishing. The owl types
one short line into that mouse's own pane, once, and never the original prompt. This is
one of the two exceptions to the rule that Whiska types only into its own house's main
session (ADR-0044); the other is the doorbell (ADR-0080). It builds rung three of
ADR-0026's ladder, "one corrective nudge, one shot", with a detector that record did not
have, and invents no third word for what it finds.

## The problem

The person closes their laptop. A mouse's turn dies on a network error. Claude Code does
not crash: the session sits idle, holding its whole context, with `API Error: Your
computer went to sleep mid-response` on the screen. Nothing finished, so the `Stop` hook
never fired and nothing reached the doorstep (ADR-0036). From outside, that mouse is
indistinguishable from one quietly working, so the person finds out hours later.

## A dead turn is read off the doorstep, not off the screen

A turn ends by reaching the doorstep, so the fact Whiska already owns is enough; nothing
reads a pane, which ADR-0026 and the last-action reading (ADR-0050) are both built to
avoid. Two edges come down to one word:

- **"Was seen working."** A mouse idle before it was ever prompted has not had a turn die.
  The owl keeps `worked_at` on the mouse record: when a turn last began. It is stamped at
  the take, in the mouse's own `UserPromptSubmit` hook (ADR-0080), which is a turn
  beginning whether or not the owl is up; from herdr's status subscription when a pane
  starts working; and by the sweep when it sees a pane it knew was quiet start working.
  Only a transition into working is a turn beginning: a stamp on every sighting of a
  working pane would post-date a turn that ended cleanly, since the entry is written while
  the pane still works. A sweep with no memory of a pane knows of no transition and only
  remembers, the conservative direction.
- **"Nothing of its collected."** A question whose `asked_at` is at or after `worked_at`
  is that turn arriving; an entry still on the doorstep is the same thing a moment earlier.

`worked_at` is on the record rather than in memory because a turn can die while the owl
restarts. Two turns are a miss rather than a wrong pickup: a first turn that dies before
its first tool call, since a record is minted on the first `PreToolUse`, and a prompt the
person typed by hand into a mouse while the owl was down.

## A short line, never the original prompt

The session still knows what it did; nobody else does. Re-sending the prompt asks it to
redo work that may already be on disk. So the owl types:

> Your last turn ended on an error before it finished. Carry on from where you stopped, and
> check what you already did before redoing any of it.

Measured, not assumed: twenty-odd died turns across this machine's transcripts were
answered by the person with "go on" or "try again", with nothing re-read and nothing
redone. The line decides nothing, which is ADR-0026's constraint on this rung.

## One attempt, then it is stuck

A pickup that does not produce a finished turn is never repeated. The cap is a comparison,
not a counter: a mouse is picked up only when its last pickup was followed by something
reaching the doorstep. A branch whose picked-up turn dies as well is ADR-0026's **stuck**
mouse from then on, and the rest of that ladder, relaunch then escalate, is still unbuilt.

The stamp goes down before the line, and the line is typed only if that write landed; the
stamp comes back up if herdr refuses. A cap written after the typing would be no cap on
the run where the write failed.

## The settling window, and the one case that skips it

Waking brings herdr's socket back with everything else, and for a moment the owl's picture
of every pane is whatever reconnection produced: the exact moment a whole fleet of died
turns becomes visible, and a wrong reading would nudge every branch at once. So a pane has
to have been reported ready for two minutes, across separate sweeps, before anything is
typed. The clock is the owl's own memory: a fresh owl waits a window out, a pane that works
again drops its clock, herdr failing to answer throws every clock away, and a sweep taken
much longer after the last one than a backstop is not the second of two sweeps, since
nobody was watching in between, so it starts the window again.

**When the mouse's transcript ends on Claude Code's own API error, the window is skipped.**
Claude Code writes that entry itself, stamped `isApiErrorMessage`, at the moment a turn
gives up; "ends on" means the last `user` or `assistant` entry of the mouse's own, read
past the bookkeeping appended after it. The window guards against a wake making herdr
misreport a pane, and a wake cannot write that entry, so the transcript is the evidence
and it says the turn is certainly dead. The owl already reads that file (ADR-0050). A
transcript that is missing, unreadable or ends on anything else changes nothing. Not
verified: what herdr reports after an API error; if it keeps saying `working`, this never
fires and the pickup waits as before.

**Unknown is never permission**, as cleanup has it (ADR-0061). `idle` and `done` pass;
`working`, `blocked` and `unknown` do not. No pane is ADR-0026's dead mouse. Two panes in
one worktree is nobody's pane. Nothing of the mouse's may be `open` or `sent`: that is a
mouse waiting for an answer, not a stuck one. A mouse with a chased answer, answered and
not taken and the newest it asked, is never picked up: its next turn has not begun, and
the doorbell carries it on (ADR-0080). A held mouse is never picked up: the person stopped
it, and `resume <branch>` is where its carry-on line comes from (ADR-0079). The person must
not have a draft in that pane's box, read as delivery reads the main session's (ADR-0047).

## It says what it did, and what it may touch

A pickup lands in the owl's log, on the mouse's sidebar line as `↩ picked up 2m ago` until
something of that mouse's reaches the doorstep (ADR-0082), and in `whiska mice` for the
rest of the mouse's life.

The owl can make a session do work, so the bound is enforced rather than asserted. A mouse
record's path is minted from a doorstep entry, which anything in this repo can write, so
herdr's own `worktree.list` for this checkout has to name the folder, and the pane
`whiska start` recorded as the main session is never typed into (ADR-0053). An entry that
will not parse belongs to a mouse nobody can name, so while one sits on the doorstep
nothing is picked up, and the owl says so once. When the detector is wrong, the cost is
one turn in a session that was legitimately idle, told to carry on with its own work.

## Consequences

- The mouse record carries `worked_at` and `picked_up_at`, stamps never cleared
  (ADR-0007). A branch picked up twice does not exist; later rungs start from
  `picked_up_at`.
- The sweep rides the 60 s backstop beside cleanup and is handed the pane list the house
  already re-listed. Its one call of its own is `worktree.list`, made only once a mouse
  has passed everything this machine can answer by itself. It runs at open too, where it
  can never act, so the first backstop after a restart is the second sweep.

## Considered options

- **Relaunch the session** (ADR-0026's rung four). Rejected: the context surviving the
  error is what makes a two-word continue enough.
- **Ask the person first.** Rejected: a question with one sensible answer is a
  notification with extra steps, arriving while they are asleep.
- **Read the pane or the transcript for the error text.** Rejected as the detector: the
  doorstep already says it, and it would depend on Claude Code's error wording.
- **Fire on the idle event rather than a sweep.** Rejected: the case this exists for is a
  laptop waking, when the events are gone.
