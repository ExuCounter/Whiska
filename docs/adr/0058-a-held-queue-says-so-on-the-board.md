# A held queue says so on the board

Delivery holds while the main session is mid-turn (ADR-0008) and while the person has
something half-typed in its prompt box (ADR-0047). Both holds are correct and neither is
negotiable: a line typed into an occupied box lands inside what the person is writing.

Both are also silent. ADR-0047 says being held is never silent and points at
`whiska doctor`'s `held: person is typing` — but the doctor has to be run, and the person
only runs it once they suspect something. While they work in that pane, every question
queues with no sign at all, which is an afternoon of not knowing a queue exists.

## Decision

**The board says why nothing is being delivered**, on the waiting line it already draws in
this repo's Claude Code statusline (ADR-0051) — the surface the person is already looking
at, and one that never interrupts:

```
🐱 3 waiting · held: your prompt box isn't empty
🐱 1 waiting · held: this session is mid-turn
```

With every waiting question already carried by a row of its own, the reason is a line of
its own — `🐱 held: …` — so a hold is never invisible for want of a count to hang off.

**The fuse is 10 seconds.** A hold that has lasted less than that says nothing, so an
ordinary pause between triggers draws no words; past it, the reason stands until the queue
moves. Ten rather than a minute is the person's own call: a reason that flickers on during
a pause is cheaper than a queue nobody knows about.

**The gate does not change.** This is the queue reporting itself, not a new reason to
deliver, and nothing is ever typed into a box the person is mid-sentence in.

## Consequences

- **The house remembers what the gate decided** — since when, and which half held — and the
  board reads it. The hold is cleared by a delivery and by an empty queue. A hold whose
  reason changes is one hold: the clock keeps running, so alternating between mid-turn and
  a draft cannot reset the fuse forever.
- **The line is as current as the last delivery attempt, and no more.** The gate is only
  consulted on a trigger — a collection, herdr reporting the main pane idle, the backstop —
  so a person who deletes their draft and walks away without submitting leaves the board
  saying `held: your prompt box isn't empty` until the next trigger, at worst one backstop
  (a minute). That is the same worst case ADR-0047 already accepts for the question itself
  being late, and the alternative is asking herdr for the main pane's screen every two
  seconds, which is a cost ADR-0051 priced and refused.
- **A reason Whiska cannot name is still a hold.** No main session recorded, a pane not
  running Claude, herdr unreachable, a prompt herdr keeps refusing: all of them draw
  `held: your main session cannot be reached`, which is true and points at `whiska doctor`
  for which one it is.
- **`whiska watch` draws no hold.** It is the board worked out on the spot, outside the
  owl, and the hold is the owl's own state.
- **The doctor's line stays.** It says more than the board has room for, and it is still
  the place that catches a box read as occupied when it is not.

## Considered options

**A macOS notification.** Rejected by the person whose screen it is: the whole point of the
gate is not to interrupt, and a notification is an interruption with none of the gate's
care.

**Leave it to `whiska doctor`.** Rejected: that is the situation this fixes. A diagnosis
only works once you know to ask for one.

**Deliver anyway after a timeout.** Rejected outright. It is the one thing ADR-0047 exists
to prevent, and no delay makes typing into somebody's draft acceptable.

## Amendment, 2026-10-06: the word is "gated"

[ADR-0079](0079-the-person-decides-what-reaches-them.md)
gives "held" to a mouse the person put on hold, a stored status with its own row word, so
the board's line here reads `gated: your prompt box isn't empty` and `whiska doctor` says
`gated: person is typing`. Nothing about the fuse, the gate or when the line is drawn
changes; and when the person is away the line says `away` instead, since the gate is then
beside the point. CONTEXT.md's entry for this state is **Gated**.

## Amendment, 2026-10-07: the reason is on the main checkout's sidebar line

[ADR-0082](0082-a-mouses-state-is-a-line-in-herdrs-sidebar.md) takes the board out of the Claude Code statusline. The reason a queue is gated is
now the main checkout's own line in herdr's sidebar, worded to fit its width —
`⏳ gated: you're typing`, `no prompt box`, `main is mid-turn`, `main unreachable` — under
the same ten-second fuse, and not while the person is away. `whiska doctor` keeps the long
words. The gate, and when the reason is said, do not change.
