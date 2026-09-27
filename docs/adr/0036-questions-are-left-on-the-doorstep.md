# Questions are left on the doorstep; the hook never opens a socket

A mouse's `Stop` hook has to get a question to the owl. The obvious design is to connect
to the house's socket and send it — and then answer the hard question of what to do when
nothing is listening. The spec required that case to "fail loudly — never silently", but
loudly has no target: the hook is a short-lived process whose stderr lands in the mouse's
own transcript, seen by the mouse and nobody else. The one person who needs to know is the
one person it cannot reach.

So the hook does not connect at all. **It writes the question to the house's doorstep and
exits — every time, unconditionally, whether or not the owl is running.** The owl drains
the doorstep when it next sweeps that house.

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

**The owl finds entries by sweeping, not by being told.** ADR-0001 already gives every
house a sweep timer, so draining is one more thing it does and no new machinery is
introduced. The cost is latency — a question waits up to one tick. This is acceptable
because instant delivery was never the goal: ADR-0008 deliberately holds the first question
of a round for 8 seconds to get an accurate count. The tick should be short (~5s), which is
cheap for an otherwise idle process.

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
source of truth and the datagram would only ever be a hint to sweep sooner.

**Watching the filesystem** (FSEvents). Near-instant, but watchers miss events under load
and need a periodic reconcile anyway — so the sweep gets built regardless, and the watcher
is a second mechanism earning little.
