# A turn that died is picked up, once, by the owl

**Amends [ADR-0044](0044-the-statusline-redraws-on-a-timer-not-a-typed-nudge.md)**, whose
rule — nothing in Whiska types into a session that is not its own house's main session —
gains exactly one exception and otherwise stands. See "What this does to ADR-0044" below.

**Builds rung three of [ADR-0026](0026-dead-mice-and-stuck-mice-are-separate-problems.md)**
— "one corrective nudge, one shot" — with a detector that ADR did not have, and invents no
third word for what it finds.

## The problem

The person closes their laptop. A mouse's turn dies on a network error. Claude Code does
not crash: the session sits there, idle, holding its whole context, with
`API Error: Your computer went to sleep mid-response` on the screen. Nothing finished, so
the `Stop` hook never fired and nothing reached the doorstep (ADR-0036). From outside, that
mouse is indistinguishable from one quietly working, so the person finds out hours later.

## A dead turn is read off the doorstep, not off the screen

A turn ends by reaching the doorstep. That is not a heuristic — it is how a question
reaches anyone, and it happens unconditionally (ADR-0036). So the fact Whiska already owns
is enough:

> A mouse that was seen working, whose pane has gone quiet, with nothing of its collected
> and nothing of its on the doorstep, had a turn that ended without finishing.

Nothing reads a pane, which ADR-0026 and the board (ADR-0050) are both built to avoid.

Two edges the sentence has to get right, and both come down to one word:

- **"Was seen working."** A mouse idle before it was ever prompted has not had a turn die;
  it has not had a turn. So the owl keeps `worked_at` on the mouse record: when herdr last
  reported that pane *starting* to work. A stamp on every sighting of a working pane would
  be wrong — the `Stop` hook writes the entry while the pane is still working and herdr
  flips it to quiet afterwards, so a stamp in that gap would post-date a turn that ended
  cleanly and read as one that died. Only a transition into working is a turn beginning,
  and **a sweep with no memory of a pane knows of no transition**, so it stamps nothing and
  only remembers. That is the conservative direction: the cost is a turn that began while
  the owl was not watching going unpicked-up, rather than a finished one being nudged.
- **"Nothing of its collected."** A question whose `asked_at` is at or after `worked_at` is
  that turn arriving. An entry still sitting on the doorstep is the same thing a moment
  earlier, so it counts too.

`worked_at` is on the record rather than in the owl's memory because a turn can die while
the owl is restarting, and the owl must not come back having forgotten that one was in
flight. It is stamped from three places: herdr's status subscription, which catches a turn
shorter than a backstop; the sweep, when it sees a pane it already knew was quiet start
working; and `whiska reply`, because an answer typed into a mouse is itself a prompt and
Whiska is the one typing it.

**Its limits, stated plainly.** Two turns are not picked up, and both are a miss rather
than a wrong nudge:

- A mouse whose very first turn dies before it has run a single tool has no record at all,
  since a record is minted on the first `PreToolUse` (ADR-0030). In practice a turn reaches
  a tool call within seconds.
- A turn that both began and died while the owl was down: the owl comes back to a quiet
  pane, sees no transition, and the last stamp it holds is the previous turn's, which has
  an entry after it. `whiska reply` closes the common case of this — the person answering a
  question — and a prompt the person typed by hand into a mouse while the owl was down does
  not.
A laptop that sleeps is neither of those: the owl is suspended rather than restarted, so
the stamp it took before the lid closed is the one it wakes up with. That is the case this
exists for, and it is covered.

## A nudge, never the original prompt

The session still knows what it did; nobody else does. Re-sending the original prompt asks
it to redo work that may already be on disk — a file written, a commit made. So the owl
types one short line and nothing else:

> Your last turn ended on an error before it finished. Carry on from where you stopped, and
> check what you already did before redoing any of it.

**Measured, not assumed.** Twenty-odd turns across this machine's own transcripts died on
`your computer went to sleep mid-response` or `can't reach the API server`, and the person
answered nearly all of them with two words: "go on", "try again". One of them is in this
repo, on `feat/backstop-warning` on 2026-09-28: a `go on` after a sleep error resumed a
half-finished `README.md` edit at the line it stopped on, with nothing re-read and nothing
redone. The context survives the error, so the continue is enough and the re-send is the
risk.

The line states a fact and one caution. It decides nothing, which is ADR-0026's constraint
on this rung: the owl never infers, extrapolates, or decides anything on the person's
behalf. Finishing the turn properly is already in the mouse's own `CLAUDE.md` (ADR-0045),
so the line does not repeat it.

## One attempt, and then it is stuck

**A pickup that does not produce a finished turn is never repeated.** The cap is a
comparison, not a counter: a mouse is picked up only when its last pickup was followed by
something reaching the doorstep. A turn that finished stands between every two pickups, so
there is no loop, and a branch whose nudged turn dies as well is simply never nudged again.

From that moment it is ADR-0026's **stuck** mouse and nothing new: alive, not progressing,
nothing waiting on the person. The rest of that ladder — relaunch, then escalate — is still
unbuilt and still where this hands over. No third word was invented for it.

## The settling window, because a laptop waking is not a fleet dying

Waking brings herdr's socket back with everything else, and for a moment the owl's picture
of every pane is whatever reconnection happened to produce. That is the exact moment a
whole fleet of died turns becomes visible, so it is also the exact moment a wrong reading
would nudge every branch at once.

So a pane has to have been reported ready for **two minutes, across separate sweeps**,
before anything is typed. The clock is the owl's own memory, not a stamp on disk, which
gives the behaviour for free in three cases: a fresh owl has no memory and therefore waits
a window out; a pane that works again drops its clock; and **herdr failing to answer throws
every clock away** rather than letting one count through the gap. The subscription dropping
does the same, since that is usually the first sign of a wake.

"Across separate sweeps" has to be enforced rather than assumed, because a suspended owl
wakes holding a clock that now reads hours. **A sweep taken much longer after the last one
than a backstop is not the second of two sweeps** — nobody was watching in between — so it
throws the memory away and starts the window again. Without that, the first look after a
wake would see eight hours of "ready" and nudge immediately, which is the exact failure the
window exists to prevent.

**Unknown is never permission**, exactly as cleanup has it (ADR-0061). `idle` and `done`
both pass. `working`, `blocked` and `unknown` do not. No pane at all is ADR-0026's dead
mouse and not this. Two panes in one worktree is nobody's pane to type into. A pane running
something other than Claude is nothing to type a Claude prompt into.

Two more preconditions come straight from ADR-0026's own ladder, which says to rule out the
cheap explanations first: nothing of the mouse's may be `open` or `sent` (rung one — it is
not stuck, it is waiting for an answer), and the person must not have a draft in that pane's
prompt box, read exactly as delivery reads the main session's (ADR-0047).

**The stamp goes down before the line does, and the line is typed only if that write
landed**; the stamp comes back up if herdr then refuses. A cap that depended on a write
happening *after* the owl had already typed would be no cap on the run where that write
failed — and a cap written without checking would be no cap either, which is the same bug
one step along.

## It says what it did

Unattended is fine; silent is not. A pickup lands in three places:

- **The owl's log**, one line naming the branch, beside cleanup's.
- **The board** (ADR-0051), in the row's detail column, while it is news — "picked up 3m
  ago", until something of that mouse's reaches the doorstep. A branch whose picked-up turn
  died as well therefore keeps saying it, which is the stuck branch being visible rather
  than a bug. A question waiting on the person still outranks it.
- **`whiska mice`**, in a column of its own, for the rest of that mouse's life. That is
  where the person looks afterwards, and the board has by then gone back to saying what the
  mouse is doing.

## What this does to ADR-0044

ADR-0044 deleted the nudge and wrote the rule it left behind: *nothing in Whiska types into
a session that is not its own house's main session.* **That rule stands.** It gains one
exception and no other: **a mouse's own pane, when that mouse's own turn died, once.**

ADR-0044's reasoning does not reach this case, and it is worth saying why rather than
asserting it. The line it deleted went into *another house's* session, about work that
session had nothing to do with. The turn it cost was pure waste, and the model improvised
on it — three dotfiles sessions ran `whiska questions` for the wrong repo. Here the turn is
the entire point: the mouse is the one that stalled, the line is about its own unfinished
work, and the improvising it provokes is the work finishing.

ADR-0044 also rejected "gate it and rate-limit it", on the grounds that the objection was
to the turn existing at all. That holds for a redraw, which needed no turn. It does not hold
for resuming work, which cannot happen without one.

`CONTEXT.md` had already reserved this sense: its retired **Nudge** entry ends "`specs/spec.md`
uses 'corrective nudge' for a message into a *stuck mouse's own* pane — a different,
still-unbuilt idea, and the only sense the word is left with."

**The exception is not widened here.** ADR-0060's red build going to a live mouse is a
different case about a different message and asks separately.

## What the owl can now do, said plainly

ADR-0061 gave the owl the power to make a Claude Code session disappear. This gives it a
different one: **the owl can make a session do work.** It is smaller in what it destroys and
larger in what it starts, and it deserves the same plain accounting:

- A person looking at that pane sees a line appear that they did not type.
- When the detector is wrong, the cost is one turn spent in a session that was legitimately
  idle, on a message that tells it to carry on with its own work. Nothing is destroyed.
- It is bounded to panes Whiska knows as mice of its own house, and that bound is enforced
  rather than asserted. A mouse record's `path` is minted from a doorstep entry, which is a
  JSON file anything running in this repo can write (ADR-0061), so the record is not on its
  own a statement that a folder is a worktree of this house. Two things that are asked of
  somebody else decide it: **herdr's own `worktree.list` for this checkout** has to name the
  folder, the same answer cleanup takes as its last word, and **the pane `whiska start`
  recorded as the main session is never typed into** (ADR-0053). Without both, a forged
  entry pointing at the main checkout or at another repo would have named a pane the owl
  has no business in — which is what ADR-0044 forbids, so claiming the bound and not
  enforcing it would have been the same as not having it.
- An entry on the doorstep that will not parse belongs to a mouse nobody can name, so while
  one is sitting there nothing is picked up at all: it could be the very turn about to be
  called dead. Nothing ever moves such a file — the owl does not delete (ADR-0007) — so
  that is a standing hold on the whole house, and the owl says so once rather than going
  quiet.
- Accepted on the grounds that a mouse whose turn died has, by construction, work it was
  halfway through and nobody coming to ask about it.

## Consequences

- **The mouse record gains `worked_at` and `picked_up_at`** (migration 6). Both are stamps,
  never cleared — ADR-0007's reading of a record as history, not state.
- **The sweep rides the existing 60 s backstop**, beside cleanup, and is handed the pane
  list the house already re-listed that tick. The one call of its own is `worktree.list`,
  and only once a mouse has passed everything this machine can answer by itself — so an
  ordinary sweep opens no socket, exactly as cleanup does not.
- **It runs at open too**, where it can never act — the clocks are all fresh — purely so the
  first backstop after an owl restart is the second sweep rather than the first.
- **A branch picked up twice does not exist.** If the ladder's later rungs are ever built,
  `picked_up_at` is where they start from.

## Considered options

**Relaunch the session instead** — ADR-0026's rung four. Rejected for this case: the whole
reason the nudge is safe is that the context survived the error, and relaunching throws away
the one thing that makes a two-word continue enough.

**Deliver it to the person as a question first** — "this branch stalled, carry on?". Rejected
for ADR-0061's reason: a question with one sensible answer is a notification with extra
steps, and this one would arrive while they were asleep.

**Read the pane, or the transcript, for the error text.** Rejected. The pane is what ADR-0026
refuses to read; the transcript would work (ADR-0050 already reads it) but buys nothing the
doorstep does not already say, and it would make the detector depend on Claude Code's own
error wording.

**Fire on the idle event rather than on a sweep.** The idle trigger's retries already notice
an empty doorstep (ADR-0036), so this looks like the natural home. Rejected: the case this
exists for is a laptop waking, when the owl was suspended and the events are gone. A detector
that only works when nothing went wrong is not one.

## Amendment, 2026-10-06: a held mouse is never picked up

A mouse the person put on hold
([ADR-0079](0079-the-person-decides-what-reaches-them.md))
ends its turn because the hook refused its next tool call, which from outside is a pane
that was working and went quiet with nothing collected — exactly the shape above. It is
not a dead turn: the person stopped it, and a line telling it to carry on would undo
that. `resume <branch>` is where that line comes from, typed by the person's own command.

## Amendment, 2026-10-06: a turn begins at the take, and a chased answer is not a died turn

[ADR-0080](0080-an-answer-is-taken-not-typed.md) stops
typing answers into the pane: `whiska reply` saves the answer and rings a doorbell, and
the mouse's own `UserPromptSubmit` hook hands the answer over. A doorbell can be
swallowed, so ringing one proves no turn began, and the third place `worked_at` was
stamped from — "`whiska reply`, because an answer typed into a mouse is itself a prompt"
— would have read a swallowed doorbell as a died turn two minutes later. **`worked_at` is
stamped at the take instead**, in the mouse's own session, which is a turn beginning.

**A mouse with a chased answer — answered, not taken, and the newest question it asked —
is never picked up.** Its next turn has not begun; the owl's doorbell is what carries it
on, and "your last turn ended on an error" would be wrong about it.

The limit above that `whiska reply` closed — a turn that began and died while the owl was
down — is closed by the take the same way: the hook stamps whether or not the owl is up.

## Amendment, 2026-10-07: an API error skips the settling window

On `feat/sidebar-status` the answer to a question arrived at 15:40:49 UTC, Claude Code
wrote `API Error: The response stopped arriving` at 15:44:24, and the person typed "try
again" by hand at 15:45:59. The owl would have stepped in only after the two-minute
window plus the next backstop sweep: two to three minutes of a mouse that looked as if it
were working.

**When the transcript's last real entry is an API error, the settling window is skipped.**
Claude Code writes that entry itself, stamped `"isApiErrorMessage": true`, at the moment a
turn gives up. "Last real" means the last `user` or `assistant` entry of the mouse's own,
read past the bookkeeping Claude Code appends after it (`turn_duration`, snapshots, mode
changes); anything the person, the owl or the mouse says after the error makes it no
longer last. The owl already reads this file for the board (ADR-0050), and this reads the
same tail, nothing more.

**Why the window has nothing left to guard against.** It exists because a laptop waking
makes herdr misreport every pane, so a quiet pane proves little. A wake cannot write an
API-error entry into a transcript, so for this one case the quiet pane is no longer the
evidence: the transcript is, and it says the turn is certainly dead.

**What does not change.** Every other rule above stands: the pane must still be reported
`idle` or `done` (a `working` pane is not typed into, whatever the transcript says), one
attempt per died turn, never the main session's pane, nothing waiting or chased, not
held, and herdr's own `worktree.list` has to name the folder. A transcript that is
missing, unreadable or ends on anything else changes nothing: the window applies as
before. A turn that died for a reason with no such entry (a sleep that cut the response
off before Claude Code could write it) still waits the window out.

**Not verified: what herdr reports after an API error.** herdr reads agent status from the
screen (its Claude hook reports only the session id), and an error screen shows the prompt
box with no spinner, so it most likely reads `idle`. That was not observed. If herdr
instead keeps saying `working`, this amendment never fires and the pickup is as before.
