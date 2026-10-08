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
every time. The board's orphan count (ADR-0082) therefore only ever goes up, across every
repo, and means nothing. A count that only grows is not a signal.

## Decision

**A question whose mouse's branch landed in the base is `settled`, not `orphaned`.** The
merge was the answer. The row is kept, as everything is (ADR-0007), with a status that
says it was dealt with.

Two new things carry it:

- **`settled`**, a terminal question status. Not waiting, so it leaves the delivery queue
  and frees the slot exactly as orphaning did (ADR-0008). Not orphaned, so it is counted
  on neither of the board's lines and listed by neither half of `whiska questions`.
- **`landed_at` on the mouse record**, stamped by the owl's sweep the first time it sees
  that branch's work reach the base. ADR-0061's first precondition — `merge-base
  --is-ancestor` — is asked of every mouse rather than only of the ones about to be torn
  down, and one more question is asked behind it.

### Landed is not the same question the teardown asks

A commit is its own ancestor, so **a branch cut an hour ago and not yet written to is an
ancestor of the base**. A mouse record is minted on its first tool call, seconds after
`spawn-worktree`, and the sweep runs every minute — so an ancestor test alone would stamp
nearly every mouse while its branch was still empty, and then settle its questions however
the work ended. That is the orphan count inverted rather than fixed: permanently zero
instead of only ever growing.

So a landing is **work the base reached through a merge**: an ancestor of the base that is
*not* on the base's own first-parent line. A branch that never moved sits on that line; a
branch merged with a merge commit hangs off it as a second parent. Two cheap commands
answer it — how far back along the line the base reaches this commit, and what is actually
there.

A branch fast-forwarded into the base is on the line like any other and reads as no
landing. That is the conservative answer and it is the honest one: afterwards nothing
distinguishes a fast-forwarded branch from one that never moved. A squashed or rebased
branch is not an ancestor of the base at all, so it never reaches this question — the same
limit ADR-0061's teardown already has.

For the same reason, the **base branch is never read as a landing**: it is merged into
itself by construction.

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

**Every order gives the same answer.** The branch may land before the mouse dies or after
it, and a question may be collected from the doorstep after both. So the stamp settles
what the mouse already had `orphaned`, the cascade reads the stamp, and collection asks
the same thing of a mouse whose worktree has gone. No order leaves a question in the wrong
state.

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

The deliberate version of that is a forged doorstep entry naming a branch that has
obviously landed, which would make a real unanswered question read as dealt with. It is
bounded by the same thing ADR-0061 bounds the record's `path` by — anything able to write
the doorstep already runs as the person and could write the database directly — and the
one cheap case is closed outright: **the base branch is never read as a landing**, since
it is merged into itself by construction. A branch ref is only ever consulted for a
worktree that has gone; while one stands, its own head is the authority.

### Why `settled` is its own status rather than `closed`

`closed` is already two things — a `done` report closed once the person has read it, and a question the
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
- **A record that never stood for a worktree.** ADR-0008's phantom — the ordinary folder
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
  `whiska reply` to one says it is already settled, and `whiska close` still takes it —
  the way out if one is ever settled wrongly.
- **Migration V005** adds `landed_at`. Existing records have none, so questions orphaned
  before this shipped stay orphaned; they are bookkeeping, not a migration's job.
- **The sweep asks git a little more.** Three or four local git commands per minute for
  every mouse record not yet stamped — which is more than the standing worktrees, since a
  record whose worktree was dropped by hand is never stamped `removed_at` and keeps being
  asked about for as long as its branch exists. At a handful of worktrees it is a fifth of
  a second per sweep; it grows with the house's lifetime record count rather than with
  anything in flight, and the cheap fix if it ever bites is to stamp such a record. One
  sweep asks one standing worktree the ancestor question once: the teardown reads the
  answer this step already got. The two commands behind the merge question are paid once
  per mouse, on the sweep that stamps it.
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
