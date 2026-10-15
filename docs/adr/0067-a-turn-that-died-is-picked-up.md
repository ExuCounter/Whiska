# A turn that died is picked up by the owl: once, or until its API error clears

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
  A mouse whose last stop was passed over for background work of its own (ADR-0052) left
  nothing on purpose: it is waiting on that work, not dead, and is left alone, even once
  that work is half an hour old, when the board calls it stuck instead (ADR-0082). A turn
  that died on an API error is still picked up whatever work is out.

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

## One attempt, unless the turn died on an API error

A pickup that does not produce a finished turn is not repeated, with one exception. The cap
is a comparison: a mouse is picked up only when its last pickup was followed by something
reaching the doorstep. A branch whose picked-up turn dies as well is ADR-0026's **stuck**
mouse from then on, and the rest of that ladder, relaunch then escalate, is still unbuilt.

**The exception is a picked-up turn that itself ends on Claude Code's API error**, written
after the pickup: an outage that clears by itself, which the person had to notice by hand
when a pickup on 2026-10-15 hit the same network error and the mouse sat silent. It is
picked up again on a schedule read off the entry's structured `error`, never its wording:

- `server_error` (asleep, offline, a cut stream, a timeout): 2, 4, 8 and 16 minutes after
  the previous pickup, then every 30, with no limit.
- `authentication_failed`: every 10 minutes, with no limit. A `/login` in any session
  revives the ones already running (seen in a transcript on 2026-10-01: "Login expired" at
  22:23, "go on" answered at 04:52 with no login of its own), and a refused login costs
  nothing. Whiska never reads the credentials to learn of the login.
- `rate_limit`: once the `quotaLimits.resetsAt` the entry carries has passed, the first
  pickup too.
- Any other kind, `invalid_request` and `model_not_found` among them, is no outage, and is
  never picked up, the first time included.

Waits count from the previous pickup, which the owl recorded, not from the error. Every
time in the transcript is somebody else's text: an error counts as the pickup's own only
when the prompt its turn began with is the pickup's line, recorded no earlier than the
pickup and not after now; a reset or error time more than eight days from now, or a reset
the last pickup already waited for, is ignored; and no retry is sooner than two minutes
after the last pickup. A local command typed after the error, `/login` among them, starts
no turn and is read past. A pickup whose turn ends any other way leaves the mouse stuck, and its
line stops saying what it waited out. Nothing
checks the network first: offline, a pickup fails before any request leaves the machine,
so it costs two lines in the pane and no tokens, and a check would be the owl's second
networked job (ADR-0060) aimed at a host a proxy may not use. The bounded cost is a stream
that keeps cutting off while the network works, each pickup re-sending the context; the
30-minute ceiling bounds it.

The person is told once per run of failures, by a hoot and no question: an expired login
at once, every branch of a house that hit it in one sweep in one hoot; a kind never picked
up, at once; a server error after its third failed pickup; a rate limit never, since its
reset is on the sidebar. A finished turn ends the run. A run that turns into an expired
login partway through is told again, since only the person can fix that. The pickup count, the error waited
out, when the run began and when it was told are on the mouse record, so an owl that
restarts neither forgets the backoff nor tells twice.

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
rest of the mouse's life. While a turn that died on an API error waits for its next
pickup, the line says what it waits out instead: `↻ API error · retry in 4m`,
`🔑 login expired · run /login`, `⏳ limit · resets 17:00`, or `✖ API error` for a kind
never picked up; the `🔑` and `✖` lines sort with stuck mice.

The owl can make a session do work, so the bound is enforced rather than asserted. A mouse
record's path is minted from a doorstep entry, which anything in this repo can write, so
herdr's own `worktree.list` for this checkout has to name the folder, and the pane
`whiska start` recorded as the main session is never typed into (ADR-0053). An entry that
will not parse belongs to a mouse nobody can name, so while one sits on the doorstep
nothing is picked up, and the owl says so once. When the detector is wrong, the cost is
one turn in a session that was legitimately idle, told to carry on with its own work.

## Consequences

- The mouse record carries `worked_at` and `picked_up_at`, stamps never cleared
  (ADR-0007), and `pickups`, `stall_kind`, `retry_at`, `stall_failed`,
  `stalled_at` and `stall_hooted_at` for a turn that keeps dying on an API error. Only such a turn is ever
  picked up twice in a row; later rungs start from `picked_up_at`.
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
  doorstep already says it, and it would depend on Claude Code's error wording. The
  transcript's structured `error` field is read only to choose the retry schedule.
- **Check the API is reachable before typing.** Rejected: see the exception above.
- **Ask a question when a run of failures goes on.** Rejected by the person for one hoot:
  nothing about it needs an answer.
- **Fire on the idle event rather than a sweep.** Rejected: the case this exists for is a
  laptop waking, when the events are gone.

Changed on 2026-10-14: a mouse whose last stop was passed over for its own background work is never picked up (ADR-0052).
Changed on 2026-10-15: a picked-up turn that dies on an API error again is picked up again, on a schedule by the error's kind, and the person is told once.
