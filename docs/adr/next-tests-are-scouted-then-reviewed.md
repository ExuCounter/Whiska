# A mouse's test is scouted before the code and reviewed at finish, when there is a test to touch

Follows ADR-0063 and ADR-0055. Takes up, narrower, two parts of ADR-0072 (proposed, not
applied): its required **wio** reviewer row, and its "wio's other two agents" section.

ADR-0063 made a mouse name the failing test that proves "done" before writing code. It did
not say how the test is chosen, so a mouse invents one: usually the happy path it was about
to write anyway. The wio skill ships two read-only agents that answer the question properly
— `wio-candidate-scout`, which ranks what is worth testing by risk, and `wio-test-reviewer`,
which says KEEP, REDO or REMOVE for a written test. This wires each into the moment it
fits.

## The scout goes in the block, the reviewer in `whiska-finish`

**The scout is one clause on ADR-0063's bullet in the `worktrees` part.** Its moment is
before code, while the work is still cheap to change. `whiska-finish` loads when a turn is
ending, which is too late to choose a test. ADR-0055 says a rule that matters at one moment
goes in a skill and the block keeps the trigger; here the trigger *is* the rule — one
agent, one condition, one fallback — so a skill of its own would hold one sentence and cost
a lookup on every build. The bullet it joins is already the trigger, so it rides there.

**The reviewer is a fifth axis in `whiska-finish` step 3**, beside correctness, security,
performance and frontend, under every rule that step already has: read before dispatch,
disproved before believed, one word per finding. It costs nothing until a turn ends, which
is what ADR-0055 moved the pipeline into a skill for.

## Both are gated

- **The scout** is skipped for a tweak, a docs change, or a change no test can reach.
- **The reviewer** runs only when the change adds, edits or deletes a test file, read from
  `git diff --name-only` against the merge base, so two mice on one diff agree.

ADR-0072 proposed wio on every finished turn, "even when no test changed", to ask what the
touched behaviour promises that no test asserts. The person chose the gate instead: a
change with no test surface should not pay for a test reviewer. The cost is ADR-0072's
case — a guard whose allowed side nobody tests, on a branch that edited no test. The scout
is the partial answer: it runs before code and ranks exactly that kind of gap, so the test
that would catch it gets written in the first place.

## A missing wio is one line, not a written prompt

wio is not shipped by Whiska and most machines will not have it. Where it is missing, the
scout's absence is said in one line and the mouse names the test itself, as before this
record; the reviewer's absence is said in one line and the axis is skipped.

This is the one exception to ADR-0054's "nothing listed for an axis → write the prompt".
A written prompt would imitate wio's judgment under wio's name and look like coverage it
is not. The line keeps the gap visible.

## Verdicts map onto ADR-0054's words

REDO or REMOVE on a test this change added or edited is **important**; on any other test,
**pre-existing**. A test is removed for being worthless, never to make a check pass — the
same limit step 2 puts on deleting an assertion. Taken from ADR-0072's proposed text.

## Not taken up

`wio-strategy-critic`, which challenges a test plan before tests are written, is not wired.
ADR-0072 recommended seeing whether the scout and the reviewer catch enough first.

## Consequences

- Every mouse on a machine with wio scouts before a non-trivial build. The block grows by
  three lines, and its length ceiling in `ClaudeMdTest` was raised by exactly that, on
  purpose — the ceiling exists to catch accretion nobody chose.
- Whiska's installed text names a third-party skill's agents. If wio renames them, the
  rules say "not listed" in one line and carry on; nothing breaks.
- If ADR-0072 is applied later, its wio row should be rewritten to this gate, or this
  record superseded.
