# A mouse's test is scouted before the code and reviewed at finish, when there is a test to touch

Two of the wio skill's reporting agents are wired into the moments they fit.
`wio-candidate-scout` ranks what is worth testing by risk, and runs before any code is
written, while no failing test is named, over the files the change will touch. It runs
only when a touched module has no test file, the brief names no observable behaviour, or
three or more modules change; otherwise the mouse names the test and says in one line the
scout was skipped. It is skipped for a docs change or one no test can reach, and a
follow-up turn on the same task does not scout again. `wio-test-reviewer` says KEEP, REDO
or REMOVE for a written test, and runs as finishing's tests axis only when the change
adds, edits or deletes a test file, support files under a test directory included, read
from `git diff --name-only` against the merge base. Both run on the model `whiska shape
--rules` picks for a clear task of known shape.

## Why

ADR-0063 makes a mouse name the failing test that proves "done" before it writes code,
and says nothing about how that test is chosen, so a mouse invents one: usually the happy
path it was about to write anyway. The scout answers that at the one moment it is cheap
to act on. The reviewer answers whether a written test is worth keeping, at the moment
every other reviewer already runs.

**The scout is a clause in the `work` part of a mouse's rules, the reviewer a row in
`whiska-finish`.** The scout's moment is before code, and `whiska-finish` loads only as a
turn ends. The trigger is the rule here, one agent, one condition, one fallback, so a
skill of its own would hold one sentence and cost a lookup on every build (ADR-0081).

**Both are gated** so a change with no test surface does not pay for a test reviewer. The
cost accepted is a guard whose allowed side nobody tests, on a branch that edited no
test; the scout is the partial answer, since it runs first and ranks exactly that kind of
gap.

**A name is something a repo can squat.** Naming the two agents gives every repo a name
to fill, and a project's `.claude/agents/` overrides a user agent of the same name. So the
repo's copy is the one that runs, and it is the file read before dispatch, under
finishing's rule for every agent definition (ADR-0049).

**A missing wio is one line, not a written prompt.** wio is not shipped by Whiska and most
machines will not have it. Where it is missing, the scout's absence is said in one line
and the mouse names the test itself; the reviewer's absence is said in one line and the
axis is skipped. This is the one exception to finishing's "nothing listed for an axis,
write the prompt": a written prompt would imitate wio's judgment under wio's name and
look like coverage it is not.

**Verdicts map onto finishing's words.** REDO or REMOVE on a test this change added or
edited is **important**; on any other test, **pre-existing**. A test is removed for being
worthless, never to make a check pass, the same limit step 2 puts on deleting an
assertion.

## Considered options

- **wio on every finished turn, even when no test changed**, to ask what the touched
  behaviour promises that no test asserts. The person chose the gate instead.
- **`wio-strategy-critic`**, which challenges a test plan before tests are written. Not
  wired until the scout and the reviewer prove they catch enough.
- **A size exemption for a tweak.** Gone with ADR-0078: a tweak scouts like any task.

## Consequences

- Every mouse on a machine with wio scouts before a build.
- Whiska's rules name a third-party skill's agents. If wio renames them, the rules say
  "not listed" in one line and carry on. A repo that ships its own copy under either name
  gets that copy read before it runs.
- A REMOVE on a guard test this change wrote is a finding like any other: disproved
  against the code before anything is deleted (ADR-0049).
