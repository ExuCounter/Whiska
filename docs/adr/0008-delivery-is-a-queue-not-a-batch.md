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

A `done` report is outside this sweep. Nothing is waiting on the person in one, and
releasing it would turn the ordinary end of a mouse's life into silence.

## What frees the slot

- **An answer.** `whiska reply` saves it; the question is `answered` and the slot is free
  whether or not the mouse has taken it yet (ADR-0080).
- **The mouse's own newer question.** When a mouse's newer question is collected, its
  earlier questions still `open` or `sent` become **superseded**. A delivered question does
  not always get its answer through `reply`: the person types into the mouse's pane, or
  the mouse moves on and finishes another turn. The mouse has moved past the question, and
  an answer could no longer land in the conversation it was asked in, which is why answers
  are keyed to a question id (ADR-0005). Settled history is untouched. A `done` report
  supersedes an earlier open question too: the mouse declared itself finished.
- **`dismiss`** (`whiska close <id>`), by hand, for a question dealt with some other way
  from a mouse that has not spoken since. It closes an orphaned question too.
- **A hold on the branch** (ADR-0079), and the mouse's death.

## A finished line waits for the slot, goes first, and then holds it

A finished line is a report, not a question, but typing it makes the main session take a
turn that prints the report and its options over whatever the person was reading. Seen
live: a spec waiting for the person's ok was sent, and while they were still reading it the
owl typed the next branch's finished line on top. So a finished line waits while any
question is out, goes ahead of every merely queued question once the slot is free (oldest
report first), and several that piled up go one per prompt, each line counting the rest
apart from other questions. The gates apply to it as to any line.

Once typed, it holds the slot until the person's next prompt in the main session, whatever
that prompt says. The main session reads each prompt against the branch last shown, so a
second finished line landing before the person has written anything would make a bare
letter ambiguous. The report is left `sent`; the `UserPromptSubmit` hook (ADR-0080), which
runs in the main session too, closes it on the person's prompt. The owl raises a flag
file, `whiska-finish` in the main checkout's `.git`, as it types the line and the hook
lowers it, so a main session with nothing out never starts the escript. `dismiss`, a hold,
the mouse's next message and the mouse's death free it as they free any sent question.

The cost, accepted: while a decision sits unanswered a finished branch gets no line and no
hoot, for as long as the decision does. The mouse's sidebar line, `inbox` and
`whiska questions` say `finished · queued behind #n`, and `dismiss` frees the slot. The
orphan window grows with it: a finished mouse whose pane closes before its line arrives is
never told, and shows only on the orphaned line.

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
- **Leave a stuck slot for the person to close by hand.** Rejected: the failure is silence
  from every other mouse, which the person reads as the mice being quiet, the direction
  ADR-0009 chooses against.
- **Time out a `sent` question.** Rejected: no timeout fits both a quick yes and a decision
  the person sits on for a day.
- **Release unanswerable questions only on reconcile.** Rejected: reconcile walks mice, and
  the wedge is a question that arrived after its mouse was walked.
- **Refuse to record a question for a dead mouse at collection.** Rejected: the house never
  judges liveness on collection, because a pane list a moment stale would cost the question
  just collected (ADR-0026).
- **One line for several finished branches.** Rejected: it changes the line the
  `whiska-delivered` skill reads, and puts several finishes into one reply.
- **A time cap on a waiting finished line.** Rejected: it brings back the interruption.
- **No hold after a finished line, every answer keyed to its question** (firstmate's way).
  Rejected: firstmate lists decisions and waits to be asked, while Whiska types into the
  person's prompt box, so a second report prints over the one being read.

## Consequences

- The slot's occupant is always something alive. `whiska doctor`'s line about a dead mouse
  holding the slot reports something that no longer persists.
- A repo whose hook shim predates the main-session prompt hook holds a finished line until
  `dismiss`, a hold or the branch's next message; `whiska doctor` fails such a shim, and
  `whiska init` rewrites it.

Folded in on 2026-10-08: 0037, 0057 (their text is in git history).
