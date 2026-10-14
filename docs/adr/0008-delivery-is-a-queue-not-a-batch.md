# Delivery is a queue, not a batch

A house types one question at a time into its main session, oldest first, and only when
that pane is idle, its prompt box is empty (ADR-0047) and no other question of the house
is `sent`. Everything else waits in the queue. There is no timer and no batching window:
that one rule is what stops the person being pinged twice for things that land close
together. The single exception that earns a timer is the first question of a round: when a
collection finds the house quiet, the first line waits up to 8 seconds so that the count
it carries is right.

Before the gate is consulted, `Whiska.Delivery.Mode` judges the queue against what the
person set aside (ADR-0079): nothing goes while they are away, only the focused mouse's
under a focus, never a held mouse's. A `sent` question of a held or unfocused mouse does
not hold the slot; it stays `sent`, since nothing is delivered twice, and the queue moves
past it.

## Nothing that cannot be answered holds the slot

Before every delivery attempt the house releases what nothing can act on: a question still
`open` or `sent` whose mouse is dead (ADR-0026), or whose record no longer stands for a
worktree of this house. Released means **settled** where the mouse's branch landed, since
the merge was the answer (ADR-0064), and **orphaned** where it did not. Both are kept
(ADR-0007), counted on the orphaned line rather than as waiting, and listed apart by
`whiska questions`, which says there is nowhere to reply. The owl says on stderr what it
released.

The rule is judged at the moment of delivery, not only at the moment of death. Seen live: a
mouse was marked dead, an entry it had already left on the doorstep was collected
afterwards and recorded `open`, delivery sent it, and the death's cascade never ran again.
A question belonging to a mouse that had not existed for days held the slot while two
later questions waited behind it. Judging at delivery makes the order of a death and a
collection stop mattering. A mouse that was only momentarily dead keeps the orphan: death
is reversible, orphaning is not, and un-orphaning on revival would let a question leave a
settled status, which is a larger decision.

A finished report never reaches this sweep: it is closed as it is collected (ADR-0009),
so a dead mouse's finished branch stays finished.

A question the owl asks itself is outside it (ADR-0036), while the mouse's worktree stands: it is
about the worktree, not the mouse, so a closed pane does not take it from the person. It
closes when the worktree is removed, by `whiska drop` or by cleanup, or once its folder is
gone however it went.

## What frees the slot

- **An answer.** `whiska reply` saves it; the question is `answered` and the slot is free
  whether or not the mouse has taken it yet (ADR-0080).
- **`dismiss`** (`whiska close <id>`), by hand, for a question dealt with some other way
  from a mouse that has not spoken since. It closes an orphaned question too.
- **A hold on the branch** (ADR-0079), and the mouse's death.
- **A letter.** `whiska send` supersedes what its mouse was waiting on once the mouse's
  pane takes the line, below.

What the person types in the main session answers no question, so a question keeps the
slot through it.

## A mouse's newer question takes the slot over

When a mouse's newer question is collected, its earlier questions still `open` or `sent`
become **superseded**. A delivered question does not always get its answer through
`reply`: the person types into the mouse's pane, or the mouse moves on and finishes
another turn. The mouse has moved past the question, and an answer could no longer land in
the conversation it was asked in, which is why answers are keyed to a question id
(ADR-0005). Settled history is untouched. A `done` report supersedes an earlier open
question too: the mouse declared itself finished, and the report, closed, takes nothing
over, so the slot is free.

Superseding passes the slot on rather than freeing it. When a superseded question held the
slot, the newer one inherits it: it is stored with `keeps_slot`, goes next ahead of every
other branch's question, and is typed once the gate lets it through. An
heir superseded before it was typed passes the slot on in turn. Away, a focus and a hold
are judged first, as always, so a held or unfocused mouse's heir has no priority. While the
heir waits to be typed, the sidebar line, `whiska questions` and the inbox show the rest
queued behind it.

A letter supersedes at once. The person read the question and chose to write to the
mouse rather than answer it, so from then on they wait on the mouse, not the other way
round. Seen live: a `sent` question kept the slot, its sidebar line read "waiting on you"
and every other branch's line stayed out for the whole turn the letter started, and then
for as long as that turn's own question waited. So once the pane takes the letter's line,
the mouse's open and sent questions are superseded, and the slot is free. A line the pane refuses supersedes nothing. When one of
them held the slot, the mouse's next collected message goes next once the slot is free,
ahead of every other branch's question: the mouse record keeps `reply_goes_next` until
that message spends it, whatever it says (a finished report spends it and goes nowhere), since nothing tells
which message answers the letter, and the message is stored with `goes_next`. It holds
no slot, so another branch's heir goes first: ranked with the heirs, an older reply
would be typed into the middle of the conversation about the other branch. It passes its place down as
an heir does, and the mouse's death takes it. The line typed asks the mouse, if the
letter does not answer its question, to say so and ask again. The cost, accepted: a pane
that swallows the line leaves the mouse idle with nothing out, and another branch's line
can arrive while the person waits on the reply.

Seen live: the person was discussing a sent question with the main session when its mouse
ended another turn saying only that it was still waiting. Superseding freed the slot, the
oldest open question, from another branch, was typed into the middle of that
conversation, and the mouse's own follow-up queued behind it. The cost, accepted: a
follow-up that adds nothing still gets its own line, on the branch already being
discussed.

## A finished report never takes the slot

A finished report is a report, not a question: nothing in it waits on the person. It is
closed as it is collected (ADR-0009) and hooted (ADR-0062), never typed, so it never waits
for the slot, holds it or inherits it, and questions go as if it were not there. The main
session shows one only when the person asks, from `whiska inbox`.

Seen live: a finished line held the slot until the person next wrote in the main session,
and a real question from another branch queued behind a report that needed no answer.
Typed, a finished line also made the main session print the report over whatever the
person was reading.

The cost, accepted: nothing about a finished branch is typed into the main session, so a
person reading only that session hears of it from a recap or `whiska inbox`. The hoot,
the reminder (ADR-0062) and the sidebar's `✅ finished` line (ADR-0082) are what reach
them.

## When the idle signal is unavailable, deliver anyway

herdr reports a pane's agent and its status as separate fields, which makes the broken case
unambiguous:

| herdr reports | meaning | delivery |
|---|---|---|
| `claude` + `idle` | free | deliver |
| `claude` + `working` | mid-turn | hold |
| `claude` + `unknown` | the integration is broken | **deliver anyway, and say so** |
| no agent | the main session's pane is not running Claude | a dead pane, not a busy one |

Holding on `unknown` would be choosing silence: the person would never learn why the mice
went quiet. Delivering interrupts at a slightly rude moment and carries its own
explanation.

## Considered options

- **Hold on `unknown`.** Rejected, as above.
- **A startup check in `whiska start`.** Rejected: it fires once, catching a machine that
  was already broken and missing herdr updated mid-session.
- **Free the slot on supersede, oldest open question next.** Rejected, as seen live above:
  another branch lands mid-conversation.
- **Hand the slot to the newer question without typing it.** Rejected: a follow-up with
  something truly new, a revised spec, would never be shown.
- **Leave a stuck slot for the person to close by hand.** Rejected: the failure is silence
  from every other mouse, which the person reads as the mice being quiet, the direction
  ADR-0009 chooses against.
- **Time out a `sent` question.** Rejected: no timeout fits both a quick yes and a decision
  the person sits on for a day.
- **Leave a question through a letter until the mouse's next message supersedes it.**
  Rejected, as seen live above: the slot waits on the mouse, not the person.
- **Answer the question with the letter**, as `resume` does with its line. Rejected: an
  answer frees the slot but hands it to nobody, so the mouse's reply would queue oldest
  first behind other branches.
- **Release unanswerable questions only on reconcile.** Rejected: reconcile walks mice, and
  the wedge is a question that arrived after its mouse was walked.
- **Refuse to record a question for a dead mouse at collection.** Rejected: the house never
  judges liveness on collection, because a pane list a moment stale would cost the question
  just collected (ADR-0026).
- **A finished line that waits for the slot, goes first, and holds it until the person's
  next prompt.** The decision until 2026-10-14. Rejected: a report that needs no answer
  held the slot ahead of real questions, and a flag file and a prompt hook in the main
  session existed only to let it go.
- **Keep reports `open`, and skip them in the queue.** Rejected: every reader that takes
  `open` as waiting would need a kind filter, and cleanup's quiet check would never take a
  landed worktree down.

## Consequences

- The slot's occupant is always something alive. `whiska doctor`'s line about a dead mouse
  holding the slot reports something that no longer persists.
- The main session's prompt hook has nothing to do, so the hook shim leaves a main
  checkout at once. `whiska doctor` fails a shim from before that, and `whiska init
  --global` rewrites it.

Folded in on 2026-10-08: 0037, 0057 (their text is in git history).

Changed on 2026-10-14: a question the owl asks itself waits while its worktree stands,
whether the mouse is alive or not, and closes with the worktree. It is not its mouse's:
it neither supersedes the mouse's questions nor is superseded by them.

Changed on 2026-10-14: `whiska send` supersedes the questions its mouse was waiting on
once its pane takes the line, rather than leaving them to the mouse's next message, and
that message goes next, behind any heir, when one of them held the slot.

Changed on 2026-10-14: a finished report never takes, holds or inherits the slot. It is
closed as it is collected and hooted, never typed; the finish flag and the main session's
prompt hook went with the line.
