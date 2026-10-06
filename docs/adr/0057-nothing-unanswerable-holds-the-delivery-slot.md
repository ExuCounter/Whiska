# Nothing that cannot be answered holds the delivery slot

Delivery is a queue with one slot: a question is `sent`, and nothing else is told until it
is answered, superseded, closed or orphaned (ADR-0008). ADR-0026 frees the slot when a
mouse dies, by cascading everything it left waiting to `orphaned`.

That covers the death, and only the death. Seen live in one work repo: a mouse was marked
dead, an entry it had already left on the doorstep was collected afterwards and recorded
`open`, delivery picked it up and marked it `sent` — and the cascade never ran again, so a
question belonging to a mouse that had not existed for days held the slot while two later
questions waited behind it. The same wedge is reachable without a death at all: a record
that no longer stands for a worktree of this house — the phantom a slashed branch's parent
folder mints, or any stale record under ADR-0051's rule — can hold the slot, because
`Whiska.Storage.current_mice/0` was applied by the board and by pane matching and by
nothing else.

## Decision

**A question nothing can act on never holds the one slot, whatever made it unanswerable.**
Before every delivery attempt the house releases what cannot be answered: a question still
`open` or `sent` whose mouse is dead (ADR-0026), and one whose mouse record no longer
stands for a worktree of this house (ADR-0051). Released means **orphaned** — the status
CONTEXT.md already gives a question whose mouse died or whose worktree is gone. It is kept
with that status (ADR-0007), counted on the board's own `orphaned` line rather than under
`waiting` (ADR-0051's addendum), and listed apart by `whiska questions`, which says there
is nowhere to reply.

**A `done` report is outside the sweep.** Nothing is waiting on the person in one, so it
neither takes the slot nor holds it (ADR-0008, note of 2026-10-01) — this rule has no
business with it, and releasing it would turn the ordinary end of a mouse's life (write
the finished line, close the pane) into silence. The cascade at the moment of death still
orphans a report, which is ADR-0036's recorded decision and is left exactly as it stands.

`Whiska.Storage.mark_dead/1` keeps its cascade and now runs it for a mouse already marked
dead, so a question collected after the death is released at the next reconcile as well as
at the next delivery.

## Consequences

- **The rule is judged at the moment of delivery**, not only at the moment of death. The
  order in which a death and a collection happen stops mattering, which is what the live
  failure turned on.
- **The slot's occupant is always something alive.** `whiska doctor`'s line about a dead
  mouse holding the slot becomes a report of something that no longer persists rather than
  a diagnosis the person has to act on.
- **A released question is told about, not hidden.** The owl says on stderr what it
  released and by which id, and the board's `orphaned` count carries it afterwards.
- **A mouse that was only momentarily dead keeps the orphan.** Death is reversible —
  `Whiska.Storage.set_pane/2` clears `died_at` when the pane is seen again — and orphaning
  is not. A pane herdr lists for a moment without an agent is enough to mark a mouse dead,
  and anything it was waiting on is released; if it comes back, the question it asked is
  settled and `whiska close`'s counterpart is a fresh ask. The sweep widens the window in
  which that can happen from the death itself to every delivery attempt. Accepted for now:
  the alternative is un-orphaning on revival, which would mean a question could leave a
  settled status, and that is a larger decision than this one.
- **An orphan is still kept.** Whether an orphaned question should be dropped outright when
  its worktree is dropped is a separate question, deliberately left open; today's
  behaviour — kept, never deleted — stands (ADR-0007).

## Considered options

**Release only on reconcile.** Simpler, and it is where ADR-0026 already acts. Rejected:
reconcile walks mice, and the wedge is a question that arrived after its mouse was already
walked. Delivery is the one place that sees the queue as it is about to be used.

**Refuse to record a question for a dead or stale mouse at collection.** Rejected for the
dead case: the house deliberately never judges liveness on collection, because a pane list
a moment stale would cost exactly the question just collected (ADR-0026). Judging at
delivery needs no such caution — the record is read fresh each time.

**Let the person close it by hand.** `whiska close <id>` already exists and already works
(ADR-0037). Rejected as the mechanism: the failure is silence from every other mouse, which
the person reads as the mice being quiet rather than as a stuck slot — the direction
ADR-0009 chooses against.

## Amendment, 2026-10-06: nor does a question the person set aside

[ADR-next-the-person-decides-what-reaches-them](next-the-person-decides-what-reaches-them.md)
adds two more things that never hold the slot, both of them answerable: a `sent` question
whose mouse the person put on hold, and one whose mouse is not the focused one while a
focus is on. Neither is released — it stays `sent`, since it was delivered and nothing is
delivered twice — but the queue moves past it as though the slot were free. The rule
above is otherwise unchanged, and the release before every attempt still runs first.
