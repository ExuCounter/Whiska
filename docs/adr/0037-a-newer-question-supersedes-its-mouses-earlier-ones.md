# A newer question supersedes its mouse's earlier open and sent ones

Delivery holds every other question while one is out waiting for its answer (ADR-0008).
That slot is freed by `whiska reply`. But a delivered question does not always get its
answer that way: the person types straight into the mouse's pane, or the mouse simply
moves on and finishes another turn. Either way the sent question would stay sent forever,
and every question from every other mouse would wait behind it.

So when a mouse's newer question is collected, its earlier questions that are still open
or sent become **superseded**. The mouse has moved past them: an answer could no longer
land in the conversation it was asked in, which is the whole reason answers are keyed to
a question id (ADR-0005). Settled history — answered, closed, orphaned — is untouched.

## Consequences

**A mouse cannot wedge the queue by moving on.** The common case frees itself with no
action from the person.

**`whiska close <id>` covers the rest.** A question dealt with some other way, from a
mouse that has not spoken since, is closed by hand. It also closes an orphaned question,
since the answer to a dead mouse's question goes to its worktree by hand for now.

**A superseded question is history, not a loss.** It is kept (ADR-0007) with its status,
so `whiska questions` never shows it and the record still says what the mouse asked and
that nobody answered. This includes a `done` report superseding an earlier open question
from the same mouse: the mouse declared itself finished, so the question is moot.

## Considered options

**Manual only.** Leave the slot until the person notices and closes it. Rejected: the
failure is silence from every other mouse, which the person would attribute to the mice
rather than to a stuck slot — exactly the direction ADR-0009 chooses against.

**Time out a sent question.** Rejected: no timeout is right for both a quick yes/no and
a decision the person sits on for a day, and a wrong one either re-pings for something
already handled or holds for hours.
