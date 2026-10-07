# Questions are left on the doorstep, whoever writes them

*Amended 2026-10-07 (see the end): the hook asks the owl first, over its hook socket, and
the owl writes the entry; when the owl does not answer, the escript writes it as before.
The title used to end "the hook never opens a socket".*

A mouse's `Stop` hook has to get a question to the owl. The obvious design is to connect
to the house's socket and send it — and then answer the hard question of what to do when
nothing is listening. The spec required that case to "fail loudly — never silently", but
loudly has no target: the hook is a short-lived process whose stderr lands in the mouse's
own transcript, seen by the mouse and nobody else. The one person who needs to know is the
one person it cannot reach.

So the hook does not connect at all. **It writes the question to the house's doorstep and
exits — every time, unconditionally, whether or not the owl is running.** The owl drains
the doorstep; the owl collects it when herdr reports that mouse has gone idle.

The doorstep is a directory in the house, `<main-checkout>/.git/whiska/doorstep/`, beside
the database. Each entry is stamped with `mouse_id`, branch label and timestamp.

## Consequences

**"The owl is down" stops being a case.** It is not a fallback path — it is the only path,
so there is no second code path to get wrong and no behaviour that differs between a
healthy machine and a broken one. The hook has no socket client, no connect timeout, no
retry, no error handling. It writes a file and exits.

**ADR-0033's native hook gets much smaller.** Its final shape was "read the payload, send
it down the socket, read back allow/deny". For the `Stop` path there is now no socket and
no reply — it is a file write, about as cheap as a process can be. The `PreToolUse` path
is unaffected and still needs the socket for allow/deny.

**The doorstep is in the house, not the worktree.** A worktree doorstep would be deleted
by an ordinary `drop-worktree` before the owl ever read it — silently, since nothing else
knew those messages existed. Durability was the whole reason for choosing this over
auto-starting the owl, so a store that routine cleanup can erase would defeat it. The cost
is the mirror image: a question can outlive the mouse that wrote it, and the owl may drain
one about a branch that no longer exists. That state already has a name (ADR-0026 treats
dead mice as a distinct, expected case) rather than being a new problem.

**A stale entry is recorded, not delivered.** On drain, an entry whose worktree is no
longer on disk stays in the house and surfaces in `whiska questions`, but never interrupts.
This does not contradict the loud-over-quiet rule applied everywhere else here: that rule
protects against missing something *actionable*, and a question with no worktree and no
pane cannot be acted on — there is nowhere to reply and nothing left to change. Nothing is
lost either way, since ADR-0007 keeps everything.

An entry whose worktree still exists *is* delivered even if its mouse is dead, because the
answer remains actionable: `whiska reopen <branch>` starts a fresh pane on that worktree
and delivers the saved question as its first message, and a push approval needs no mouse at
all — ADR-0011 has Whiska run the push itself.

The case is rare by construction: it requires the owl to be down *and* a worktree to be
dropped inside that same window.

`.git/whiska/` is also gitignored by construction, which is why the database lives there;
a worktree doorstep would need its own ignore entry.

**Collection is event-driven; the timer is only a backstop.** Whiska's `Stop` hook is not
the only one that fires when a mouse ends a turn — herdr's own `herdr-agent-state.sh` fires
too, marking the pane idle and emitting `pane.agent_status_changed`. The owl subscribes to
that, so it is told a mouse has stopped at the exact moment there is something to collect,
and reads that house's doorstep then. It is not polling for work; it is being woken.

Three triggers, and only one is a timer:

| Trigger | Role |
|---|---|
| `pane.agent_status_changed` → idle | primary — collect that house's doorstep now |
| owl startup | collects whatever landed while it was down |
| slow timer (~1 min) | backstop only |

The backstop cannot be dropped, and startup-only is not sufficient, for three reasons. The
two `Stop` hooks race — Claude Code does not order them, so herdr's event can arrive before
Whiska's hook has finished writing, and the owl would read an empty doorstep. herdr can be
down while the owl is up, in which case no events arrive at all and entries would sit
uncollected until the next restart. And subscriptions drop when herdr restarts on its own
updates.

Latency was never the constraint anyway: ADR-0008 deliberately holds the first question of
a round for 8 seconds to get an accurate count.

*Note, 2026-09-27.* The hook race turned out to cost a full backstop in practice: a done
report written seconds after the idle event waited the whole minute before it was seen.
The idle trigger now retries: when it reads an empty doorstep, the house looks again after
2 s and once more after 5 s, and stops as soon as any collection finds something. A second
idle event while those retries are pending adds none. The doorstep is still the only
channel, and the backstop is still the last resort — the retries only shorten the common
case.

*Note, 2026-09-28.* The primary trigger had never fired. Every collection and every
delivery since the owl was built had been running on the 60 s backstop, and last night's
retries had never run either. Two reasons, both found by subscribing to the live socket
from the main terminal: herdr streams a per-pane subscription event under its
*subscription* type, `pane.agent_status_changed` (a dot), while the global events arrive
under their *event* type, `pane_closed`, `pane_exited`, `pane_agent_detected` (an
underscore) — and the house matched only the underscore spelling, so no status event ever
matched; and a mouse ending a turn reports `done`, not `idle`. In herdr's own words,
`idle` is "ready for input and its tab has been seen in the focused UI" and `done` is
"the same underlying idle state after unseen background work finishes" — a mouse works in
a background tab, so its turn ends as `working` → `done`, with `idle` following only when
someone looks at it. The house now folds the dot spelling into the underscore one on
arrival and treats a mouse pane's `done` exactly as `idle`. The trigger table above
stands, read "idle" as "`done` or `idle`".

*Note, 2026-09-28 (later the same day).* The backstop now announces itself, so a dead
trigger cannot hide behind it again. The bug above cost weeks precisely because the
backup mechanism worked: every question did arrive, a minute late, and a minute late is
invisible to someone reading their terminal when they get to it. A last resort that is
silently doing the primary trigger's job is indistinguishable from a healthy system.

So when the backstop's collection finds anything, the house prints one warning line
naming the house and the count, and leaves a mark — a count and a timestamp in
`<main-checkout>/.git/whiska/backstop`, cleared when the owl opens the house, so it is
always about the run happening now. `whiska doctor` reads the mark and turns it into one
line: ok when the backstop has collected nothing since the owl opened this house, a
warning with the count and the age when it has, pointing at the subscription and at
`whiska owl stop && whiska owl start`. The doctor still only checks (ADR-0038).

The mark is in the house, beside the doorstep and the database, not in `~/.whiska` beside
the open-houses record (ADR-0039) — it is one house's fact, the doctor is scoped to one
repo, and per-house files mean no two houses ever rewrite the same one. It borrows
ADR-0039's shape otherwise: plain text, written to a temporary name and renamed into
place, hand-editable and safe to delete.

Two collections deliberately do not count. Collecting at open is the designed "what
landed while the owl was down" path, not a missed trigger; and the idle trigger's own
2 s and 5 s retries are the idle trigger, just slower.

**The subscription is per pane, so the house has to know its panes.** Checked against herdr
0.8.2 when this was built: `pane.agent_status_changed` can only be subscribed for a named
`pane_id` (no wildcard), while `pane.closed`, `pane.exited` and `pane.agent_detected` are
global. So a house finds each mouse's pane by matching the pane's `cwd` to the mouse's
worktree path — at open, and again whenever herdr reports a new agent pane — records it on
the mouse (the first thing that ever fills ADR-0006's `pane` column), and reopens its
subscription whenever that set changes. A mouse with no pane anywhere is a dead mouse
(ADR-0026). herdr's own Claude integration has since stopped reporting `Stop` and detects
idleness itself; the event still arrives, so the trigger table above stands.

*Note, 2026-09-29.* **The addendum below is spent.** ADR-0049 retires the review loop, so
nothing sits in front of `whiska hook stop` any more: one `Stop` entry, the shim, and this
hook. "Every time, unconditionally" is again literally true — the shim captures no stdin,
runs no script, and needs no `jq`. What the addendum decided still holds for the next
thing that wants to sit in front of this hook: chained in the shim, never a second `Stop`
entry beside it, because Claude Code runs them in parallel. The doctor's `stop` probe
still carries no `done` marker, now because a probe that looks like a finished turn is a
probe that lies.

*Note, 2026-09-28 (later again).* **"Every time, unconditionally" now means every time
the hook runs, and something else decides whether it runs.** ADR-0042 adds a second `Stop`
hook — the repo's review loop, which blocks a turn that claims to be `done` until the
repo's checks are green. Claude Code runs `Stop` hooks in parallel and does not order
them, so registered side by side the two raced: the loop blocked the turn while this hook
had already written `done` to the doorstep, and the owl delivered "finished" within
seconds of a mouse that was still working. ADR-0037 meant nothing was lost — the next
turn's entry supersedes it — but "finished" is exactly the report a person acts on without
checking, so being wrong about it for a few minutes is worse than being late.

So the two are **chained in `whiska.sh` rather than registered separately**. There is one
`Stop` entry. The shim runs `review-loop.sh` first, prints its block decision and exits if
there is one, and only then calls `whiska hook stop`.

`Whiska.Hook.Stop` is not touched, and neither is anything above. It still writes the
whole final message the moment it is asked, still never classifies, still has no socket
and no second code path. What changed is upstream of it: the shim asks whether the turn
ended before asking this hook to record that it did. The marker is read — by the repo's
script, in shell, outside Whiska — but not by anything that then decides what kind of
question this is. That judgment is still the owl's on collection (ADR-0009).

Two smaller consequences follow from where the chaining sits. The loop runs *before* the
shim's binary lookup, so a missing Whiska fails open without also disabling the repo's own
hook. And `whiska doctor`'s `stop` probe no longer sends a payload ending in `done`:
chained, that marker would set the repo's whole check command running, and the doctor
checks rather than sets things going (ADR-0038).

## Considered options

**Auto-start the owl on demand.** `launchd` socket activation would start the owl when a
mouse connects, making "down" self-healing. Rejected: it lets a hook silently spawn a
long-running service, and turns a crash-looping owl into something hard to notice.

**Block the mouse until the owl is reachable.** Strongest guarantee, worst failure: the
whole fleet wedges because a notification service is down. It also inverts the trade
`Whiska.Hook.PreToolUse` already makes, where a malformed payload allows the call rather
than bricking the session.

**Write the file, then poke the socket with a fire-and-forget datagram.** ADR-0033 endorses
exactly this shape for activity telemetry, and it would cut the latency to nothing. Not
rejected on merit — deferred, because it is strictly additive. The doorstep stays the
source of truth and the datagram would only ever be a hint to collect sooner.

**Watching the filesystem** (FSEvents). Near-instant, but watchers miss events under load
and need a periodic reconcile anyway — so the backstop gets built regardless, and the watcher
is a second mechanism earning little.

## Note, 2026-09-29: "every time" means every turn that ended

The decision above says the hook writes "every time, unconditionally, whether or not the
owl is running", and its earlier note re-asserts that. ADR-0052 narrows it in one place and
one only: a turn with a background subagent still out has not ended, so nothing is written
and the hook exits quietly.

What the sentence was defending is untouched. There is still no second code path for a
missing owl, no socket, no retry, and nothing about the state of the house changes what the
hook does. The condition is about whether the turn happened at all, read from Claude Code's
own transcript, and every way of failing to read it counts as "it happened" — so the hook
still writes whenever there is any doubt.

## Note, 2026-09-30: one row of the house does change what the hook does

The note above says "nothing about the state of the house changes what the hook does".
ADR-0053 narrows that in one place: the hook reads the pane `whiska start` recorded as
the main session, and a stop firing in that pane writes nothing, because it is the
person's own session rather than a mouse.

What the sentence was defending still holds. There is no second code path for a missing
owl, no socket and no retry, and a house that will not open — or has no main pane
recorded — makes no claim either way: the read runs through `Whiska.Isolated` so a broken
database cannot take the hook down before it writes, and the entry is left exactly as
before. The read narrows *whose* stop this is, never whether a mouse's stop is written.

## Amendment, 2026-10-07: the hook asks the owl first

ADR-0033 moved every hook onto the owl: the shim sends the payload to
`~/.whiska/hook.sock`, and the owl runs the hook's own code. For `Stop` that collides
with this record's sentence, "It writes the question to the house's doorstep and exits —
every time, unconditionally, whether or not the owl is running", and with "there is no
second code path for 'the owl is down'". The person decided it, put to them in this
repo's ADR-contradiction form.

What changes:

- **When the owl answers, it writes the entry.** It runs `Whiska.Hook.Stop` with the
  hook's own environment, and the entry lands on the same doorstep, in the same format.
  The owl then asks that house, if it is open, to collect at once, after the shim has
  had its answer. The idle trigger, its 2 s and 5 s retries and the backstop all stay;
  they are simply beaten to it in the common case.
- **When the owl does not answer, the escript writes it**, exactly as this record
  describes: no socket, no socket file, an owl hung for two seconds, an owl too old to
  know the hook — or an owl that could not write the entry itself, which hangs up rather
  than say it did. A dead owl still loses nothing, and that was the whole reason for the
  doorstep.
- **The doorstep is still the one way a question gets into a house.** Nothing goes into
  the database except by being collected from it.

What the record was defending still holds: nothing about the state of the owl changes
whether a turn's message is written, and the logic that decides it is one module, run in
one process or the other. What is gone is "one path": there are two transports now.

One new edge, accepted. If the owl writes the entry and the shim gives up waiting before
the answer arrives, the escript writes a second entry for the same turn; ADR-0037 has
the newer supersede the older, so the person sees one question.
