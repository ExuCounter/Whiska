# A mouse reads the code, then asks every choice that is costly to undo

Rewritten 2026-10-04. The first version of this record had a mouse grill only when it
could not name "done", or the failing test that proves it, without a guess. That stopped
the mouse that went straight at the code on a bug report. It let through the brief that
names its outcome and leaves the approach open. "Drop the jq dependency" names "done"
exactly — jq is gone and nothing breaks — and still hides the choice the person wants a
say in: what replaces it. A mouse passed the test and built the first replacement it
thought of.

## The rule

A mouse takes a piece of work the way a senior engineer does:

1. It reads the code first. The choices a change holds are seldom visible in the brief;
   they are visible where the change lands.
2. It sends one message listing every choice that has real alternatives and is costly to
   undo, each with the answer it recommends, and waits for the person's ok.
3. It decides the cheap choices itself and lists them in its final report.
4. A truly trivial task — a typo, a rename, a one-line fix, with nothing on the costly
   list below — needs no message.

With no costly choice left open, a mouse builds without the message. It still never asks
what the brief already spells out. "Trivial" never overrides the list: turning off a
certificate check or renaming a command-line flag can be one line, and is still costly.

The first version's test survives inside this one. A "done" or failing test that needs a
guess is a costly choice, since building the wrong thing is the most expensive thing to
undo. Before writing code a mouse still names "done" and the failing test, and ADR-0075's
scout still helps pick the test.

## "Costly to undo" is a test, not an adjective

The first version replaced "a thin brief" because it was an adjective with no test behind
it. "Costly" has the same problem, so the block gives it one. A choice is costly when
something outside the change depends on it — a file format, a command-line flag or
interface, stored data, a dependency added or dropped, behaviour the person would notice —
or when it touches secrets, access or a security check, or when the rest of the change is
built on it. Anything else is cheap.

The list is the things a reverted commit does not take back. Code inside the change can be
rewritten on the branch. A format someone has written files in, a flag someone has
scripted against, a dependency another module has started using, cannot. "The rest of the
change is built on it" covers the approach itself: swapping it later means redoing the
work, not editing a line.

Secrets, access and security checks are on the list for the opposite reason. Turning off
a certificate check, logging a token or widening an allow-list is a one-line revert that
nothing depends on and nobody notices, so the dependency test alone would call it cheap.
The harm is done before anyone reverts it, and a closed list would otherwise tell a mouse
to make that call alone.

## What stays

The whole-frontier rule from ADR-0055: the message asks every costly choice at once,
because each round costs the person a full round trip. Answers can open another round, and
every round ends with the status marker.

The 2–4 line plan still binds the main session only (ADR-0055). A mouse sends no plan; the
oks it waits for are on its costly choices and, since the 2026-10-05 amendment below, on
its spec. A costly choice found mid-build is a real
decision and stops the mouse the same way. The block says so in the bullet that tells a
mouse it builds, because that bullet, read on its own, is what once cancelled the grilling
rule.

## The alternatives

**Always send the list and wait**, even when it says "nothing to decide": the person sees
every approach before any code, at one round trip per task, including every task with
nothing to see. The final report's list of cheap choices is where the person sees the rest.

**Leave "costly" to judgment**, with only the trivial examples: shorter, but every mouse
draws the line in a different place, which is the failure the first version was written to
fix.

**Ask every choice, cheap ones included**: buries the two that matter under ten that do
not, and the person stops reading the list.

**Keep the first version**: it asks nothing about *how*, which is the gap this rewrite
closes.

## Consequences

A non-trivial task with a costly choice in it costs one round trip before any code,
including briefs the first version would have built straight away. That is the intended
cost.

A mouse's final report grows by the cheap choices it made. The `report` part gives each
a line under what changed, outside its six-line cap, so neither the cap nor the leave-out
list cuts them.

The block's ceiling moves from 145 lines and 1433 words to 152 and 1550: exactly what the
rule cost, on purpose.

No architecture diagram moves. The message is a needs-decision question like any other and
reaches the person by the same delivery flow.

## Amendment, 2026-10-05: the answers are written down and approved

ADR-0076 adds a step between the last
grilling round and the first line of code. The mouse runs `whiska-spec`, unless the task
is a tweak or quick fix. It writes the spec to an untracked `.whiska-spec.md`, sends the
whole spec as a question, and builds only when the person replies "ok". A grilled task
now costs one more round trip before any code. A brief that needed no grilling still
costs none.
