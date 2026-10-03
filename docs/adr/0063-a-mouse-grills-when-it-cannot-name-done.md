# A mouse grills when it cannot name "done", and builds when it can

The worktrees part told a mouse two things. "The mouse grills a thin brief from inside the
worktree", and, four bullets later, "A mouse does not: it builds, and stops only on a real
decision." The second is the general statement and it comes last, so it is the one that
wins: a mouse read "does not plan, builds" and went straight at the code. Bug reports and
one-line asks got implementations of whatever the mouse guessed they meant.

"Thin" was the whole condition and it was an adjective. Nothing said how a session decides
a brief is thin, which left it deciding by who was asking or by how long the message was.

## The test is the failing test

Before writing code, a mouse says in one line what "done" looks like and names the failing
test that proves it. Both read off the brief with no guess → build. Either one needs a
guess the person has an opinion on → grill first.

It is a property of the brief, not of the request's shape or its author. A long brief that
never says what right looks like fails it; a one-line brief that names the outcome passes.
A bug report usually fails it, because a report says what happened and not what should
have, and that is where the mouse was guessing most often — but "it is a bug" is not the
rule, it is the common case of the rule.

It is checkable without the person in the room, which is what the old wording was missing,
and it is the same sentence TDD already asks for, so a mouse that cannot write it cannot
start anyway.

## What stays

The 2–4 line plan that waits for an ok still binds the main session only (ADR-0055). A
mouse still does not wait for an ok — the bullet now says that this is not leave to skip
the test above, which is the sentence that was doing the damage.

A grilling round still asks the whole frontier in one message (ADR-0055), because each
round costs the person a full round trip, and a round still ends with the status marker.
The test decides *whether* there is a round at all; the frontier rule decides what one
round contains, and neither caps how many rounds the answers open.

## The alternatives

Grill every brief: pays a round trip on work that was already specific, which is the waste
the person named. Grill nothing and ask mid-build: trades one round trip for several, and
the mouse has usually written the wrong thing by then. Grill by request type — bugs yes,
features no — is the test drawn on the asker's phrasing rather than on what the brief
contains, and a vague feature request is exactly as unbuildable as a bug report.

## Consequences

The block's word ceiling moves from 1300 to 1370. The rule costs about seventy words and
the old wording was sitting on the ceiling, so something had to give; cutting a different
rule to pay for this one would have been the quiet accretion ADR-0055's ceiling exists to
catch. The line ceiling of 140 is unchanged, and the test still fails on the next addition.

A mouse now has one blocking moment it did not have: a brief that fails the test stops for
an answer before any code exists. That is the intended cost, and the frontier rule keeps
each round of it to a single message.

The bullet that says a mouse does not wait for an ok names the two rules it is not leave
to skip, rather than pointing at "the rules above": the rules it excepts are four bullets
up, and a positional pointer read literally lands on the wrong ones.
