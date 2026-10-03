# A landed branch settles what its mouse left waiting

**Refines a line of [ADR-0007](0007-nothing-is-ever-deleted.md)** — "everything it left
waiting cascades to `orphaned`". It still cascades, and nothing is deleted; what changes
is where it cascades *to*. The rest of ADR-0007 is untouched.

## The problem, from the ordinary flow

A mouse asks a question. The person reads it, answers it in conversation rather than
through `whiska reply`, and merges the branch. The worktree comes down — by the owl
(ADR-0061), by `drop-worktree`, or by hand — and nobody ever runs `whiska close`. The
question was still `sent` when its mouse went, so it cascaded to `orphaned`.

That is the normal, successful path through the system, and it leaves an orphan behind
every time. The board's orphan count (ADR-0051) therefore only ever goes up, across every
repo, and means nothing. A count that only grows is not a signal.

## Decision

**A question whose mouse's branch landed in the base is `settled`, not `orphaned`.** The
merge was the answer. The row is kept, as everything is (ADR-0007), with a status that
says it was dealt with.

Two new things carry it:

- **`settled`**, a terminal question status. Not waiting, so it leaves the delivery queue
  and frees the slot exactly as orphaning did (ADR-0057). Not orphaned, so it is counted
  on neither of the board's lines and listed by neither half of `whiska questions`.
- **`landed_at` on the mouse record**, stamped by the owl's sweep the first time it sees
  that branch merged into the base. It is the same `merge-base --is-ancestor` question
  ADR-0061's first precondition asks, asked of every mouse rather than only of the ones
  about to be torn down.

### Which teardown paths this covers: none of them, deliberately

The obvious design hangs the settling off the act of taking a worktree down. It was
rejected, and the reason is worth writing down because it decides the shape of everything
else.

**The owl's own cleanup (ADR-0061) can never be the place.** Its third precondition is
that none of the mouse's questions is `open` or `sent`. A mouse with an outstanding
question is not quiet, so the owl never takes its worktree down — there is nothing there
to settle. That precondition is right and stays: tearing a pane down under a question the
person has not answered destroys the context the answer would have gone back to.

**`drop-worktree` cannot be relied on, because it is a skill.** It is prose a session
reads and may follow — or may not, when the person removes a worktree with plain `git
worktree remove`, or deletes the folder, or does it from another terminal with no Claude
Code involved. A rule that only holds when a model happens to follow a document is not a
rule. It is also the path that actually ran in the case that prompted this, so it is
precisely the one that has to work.

So **Whiska notices by itself, and it notices the landing rather than the teardown.** The
sweep that already runs every 60 s stamps `landed_at` on every mouse whose branch has
merged, torn down or not, quiet or not. The teardown then needs no cooperation from
anyone: whenever the mouse finally has nothing left to answer to, the stamp decides which
terminal status its questions take.

Reading the landing survives the worktree going. While the worktree stands its own `HEAD`
is the authority. Once it is gone, the branch ref in the main checkout answers the same
question, which covers a worktree dropped by hand with its branch kept.

**Both orders give the same answer.** The branch may land before the mouse dies or after
it, so the stamp settles what the mouse already had `orphaned` as well as deciding what it
cascades later. Neither order leaves a question in the wrong state.

### What it does not reach, and why that is the safe side

**A branch deleted in the same breath as its worktree, before any sweep saw it merged.**
`drop-worktree` deletes the branch by default, and then nothing is left to ask. Those
questions orphan, as they do today. The window is one sweep interval, the failure is the
old behaviour rather than a new wrong one, and the person can still `whiska close` by
hand. Closing it properly would mean recording every branch's head commit continuously,
which is a great deal of machinery for a minute's race.

**A branch name taken back by a later branch that then lands.** The stamp would be read
off a ref that is no longer the mouse's. The consequence is one old question reading
`settled` rather than `orphaned`; nothing is deleted and nothing is delivered. Bounded
and accepted.

### Why `settled` is its own status rather than `closed`

`closed` is already two things — a `done` report closed as it is told, and a question the
person closed by hand with `whiska close`. Folding a third in would throw away the one
distinction this change exists to make: a question somebody dealt with, against one that
was simply abandoned. Keeping them apart is the point, and a status is the cheapest place
to keep them apart, since every reader already switches on one.

### What is still an orphan

The concept survives with a narrower, truer meaning: **a question nothing can act on and
nothing ever answered.** Two real cases remain.

- **Abandoned work.** A mouse whose pane died, or whose worktree was dropped early, on a
  branch that never landed. `drop-worktree`'s own stated use is taking a worktree down
  *before* its branch lands, so this is not a hypothetical. Nobody answered the question
  and the work it was about is gone.
- **A record that never stood for a worktree.** ADR-0057's phantom — the ordinary folder
  a slashed branch nests under — and any other stale record. There was never a branch to
  land.

Both are things going wrong, which is what the count is supposed to say. A board whose
orphan line is at zero on a normal week, and names a branch when it is not, is worth
reading.

## Consequences

- **The board's orphan count stops growing on the happy path**, in every repo. Nothing
  else on the board moves: a settled question was never counted as waiting.
- **`whiska questions` lists settled questions nowhere.** They are history, like
  `answered` and `superseded`. The id still reads in full with `whiska questions <id>`,
  and `whiska reply` to one says it is already settled.
- **Migration V005** adds `landed_at`. Existing records have none, so questions orphaned
  before this shipped stay orphaned; they are bookkeeping, not a migration's job.
- **The sweep asks git a little more.** Two or three local git commands per standing
  worktree per minute, for a handful of worktrees. The merge check was already paid for
  every quiet mouse.
- **Nothing here deletes anything** and nothing here takes a worktree down. ADR-0061's
  four preconditions are untouched, and so is the rule that a question the person has not
  answered holds its mouse's worktree in place.

## Considered options

**Settle on teardown, whatever the branch did.** The simplest rule: the folder is gone, so
the question is dealt with. Rejected — it overclaims exactly where the distinction matters.
A worktree dropped early with its question unanswered is the abandonment case, and under
this rule it would read as dealt with.

**Make `drop-worktree` run `whiska close`.** Rejected: a skill is prose, and this has to
hold when no session is involved at all. Whiska noticing by itself costs little more and
cannot be skipped.

**Record every branch's head commit so merged-ness is answerable forever.** It would close
the one-sweep race. Rejected as disproportionate: a continuously maintained commit column
for a minute's window whose failure mode is today's behaviour.

**Drop the orphan concept entirely.** Considered seriously, since this removes its common
case. Rejected: abandoned work and a phantom record are both real and both worth a line on
the board. What was wrong was that the ordinary flow produced orphans too.
