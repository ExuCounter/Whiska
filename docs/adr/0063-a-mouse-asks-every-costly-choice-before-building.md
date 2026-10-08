# A mouse grills every costly choice, writes the spec, and builds on the person's ok

A mouse reads the code first, then sends one message listing every choice that has real
alternatives and is costly to undo, each with the answer it recommends, and waits for the
person's ok. After the last round it runs `whiska-spec`, which writes the spec to
`.whiska-spec.md` at the worktree root and sends the whole spec as a question; the mouse
builds only when the person replies "ok", and any other reply revises the file and sends
it again. Cheap choices the mouse decides itself and lists in its final report. A copy of
every spec sent is kept in the main checkout.

## The rule

1. Read the code. The choices a change holds are seldom visible in the brief; they are
   visible where the change lands.
2. Ask the whole frontier in one message: every costly choice whose prerequisites are
   settled, each with a recommended answer. Each round costs the person a full round
   trip, so a round never asks one question at a time. Answers can open another round,
   and every round ends on the status marker.
3. Write the spec and send it whole. The person reads it cold, through
   `whiska questions <id>`, so the question carries the entire file.
4. Build to it. A costly choice found mid-build is a real decision and stops the mouse
   the same way; it is never a quiet edit to the spec.

With no costly choice open, a mouse builds without the message and without a spec: the
person's own words are the spec. A truly trivial task, a typo, a rename, a one-line fix
with nothing on the costly list, needs no message either. "Trivial" never overrides the
list: turning off a certificate check can be one line and is still costly. A mouse never
asks what the brief already spells out. A mouse sends no plan; the oks it waits for are on
its costly choices and on its spec. The plan binds the main session only (ADR-0081).

A "done" or failing test that needs a guess is itself a costly choice, since building
the wrong thing is the most expensive thing to undo. Before writing code a mouse names
"done" and the failing test, and ADR-0075's scout helps pick the test.

## Costly is a test, not an adjective

A choice is costly when something outside the change depends on it: a file format, a
command-line flag or interface, stored data, a dependency added or dropped, behaviour the
person would notice. It is also costly when it touches secrets, access or a security
check, or when the rest of the change is built on it. Anything else is cheap.

The list is the things a reverted commit does not take back. Code inside the change can
be rewritten on the branch; a format someone has written files in, a flag someone has
scripted against, a dependency another module uses, cannot. "The rest of the change is
built on it" covers the approach itself: swapping it later means redoing the work.
Secrets, access and security checks are on the list for the opposite reason: widening an
allow-list is a one-line revert nobody notices, and the harm is done before anyone
reverts it.

An earlier version grilled only when the mouse could not name "done" without a guess.
"Drop the jq dependency" names "done" exactly and still hides the choice the person wants
a say in, what replaces jq; a mouse passed that test and built the first replacement it
thought of. The dependency test closes that gap.

## The spec

`whiska-spec` keeps the person's template headings and asks for one screen, about 500
words: at most ten stories about the person's users, one line per costly choice citing
its ADR, and anything beyond the brief as one line under Out of Scope. The first ten real
specs ran 986 to 3,463 words, were approved unchanged, and held stories whose actor was a
mouse, docs upkeep and byte-level detail; nobody reads that. The finish pipeline's first
step reads the work back against the spec, beside the brief (ADR-0049).

The spec is a file git ignores, never committed. Untracked is not enough: the owl takes a
landed worktree down only when `git status --porcelain` reads clean (ADR-0061). So
`whiska shape` and `whiska mode` add `/.whiska-spec.md` to the main checkout's
`.git/info/exclude`, which every worktree of the repo reads and which is never committed
(ADR-0056). That write is Whiska's own process; a mouse never edits the main checkout
(ADR-0013), so the skill only checks `git check-ignore` and, if the line is missing, says
so in one line under the spec. A session working in the main checkout adds the line
itself.

Whiska ships `whiska-spec` and `grilling` from `priv/skills/`, in both scopes (ADR-0056),
so each has one copy. The mouse's rules point at `whiska-spec` only: `grilling` walks
every branch of a design, while this rule asks the costly choices and decides the cheap
ones, so pointing a mouse at it would undo the rule.

## Every spec sent is kept

`git worktree remove` deletes ignored files, and a dropped branch has no commits to hold
the outcome. So every spec a mouse sends is kept in `.whiska/specs/` in the main
checkout, one file per spec, named `<date first written>-<branch, with / as ->.md`; a
second mouse on the same branch name the same day gets `-2`. A header says the repo,
branch and mouse, the question it was last sent as, the questions earlier revisions were
sent as (`replaced:`), when it was written, and its status: `waiting`, `landed <date>,
branch head <commit>` or `dropped <date>`. A revision overwrites its file; each earlier
revision is still readable whole as its own question.

The copy is taken when the spec is sent. The `Stop` hook reads the worktree's spec into
the doorstep entry beside the message (ADR-0036), and the owl writes the copy when it
collects the entry, naming the question just recorded. An entry whose spec matches the
kept copy writes nothing. Only a regular UTF-8 file of at most 256 KB travels; anything
else is left out so the message itself still reaches the doorstep.

The cleanup sweep sets the status after it notes landings (ADR-0064). A mouse stamped
landed gets `landed` with its branch's last commit; a mouse whose worktree is gone with no
landing gets `dropped`. A dropped spec is kept (ADR-0007) and can still become landed;
landed is final. A branch landed by cherry-pick is not an ancestor of the base, so until
the landing check learns cherry-picks such a spec reads `dropped`. The owl writes
`/.whiska/` into the same exclude file the first time it keeps a spec.

## Considered options

- **Always send the list and wait**, even when it says "nothing to decide": one round
  trip per task, including every task with nothing to see.
- **Leave "costly" to judgment**: every mouse draws the line in a different place.
- **Ask every choice, cheap ones included**: buries the two that matter under ten that
  do not, and the person stops reading.
- **Build straight from the grilling answers**, no spec: costs no round trip, but the
  person's ok was on choices one at a time, never on the whole. They chose to see the
  whole spec before any code.
- **Commit the spec on the branch**: durable and reviewed, but teammates see the file in
  every repo Whiska is installed in. **The repo's issue tracker**: setup per repo, and it
  publishes outside the machine. **Only the question**: nothing for finishing to read
  back.
- **Copy the spec at worktree removal**: the sweep, `drop-worktree` and Land here would
  each have to remember, and a worktree removed by hand would still lose it. **The mouse
  copies it**: a mouse never writes to the main checkout.
- **A folder per branch with one file per revision**: specs are overwritten anyway, and
  each revision is still a question.

## Consequences

A grilled task costs two round trips before any code, one on the costly choices and one
on the spec; a brief that needed no grilling costs none. The final report grows by the
cheap choices made, each a line under what changed, outside the report's size cap. A
doorstep entry carries an optional `spec` field; an entry without one still decodes. A
house without a herdr socket leaves every kept spec at `waiting`. `.whiska-mouse` has the
same untracked-file problem in a repo whose `.gitignore` does not list it, left for a
change of its own.

Folded in on 2026-10-08: 0076, 0085 (their text is in git history).
