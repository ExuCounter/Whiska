# A mouse writes a spec for almost every brief, grills its costly choices first, and builds on the person's ok

A mouse reads the code first, then sends one message listing every choice that has real
alternatives and is costly to undo, each with the answer it recommends, and waits for the
person's ok; with nothing costly to ask it sends no such message. After the last round, or
straight away, it runs `whiska-spec`, which writes the spec to `.whiska-spec.md` at the
worktree root and sends a link to it as a question; the mouse builds only when the person
replies "ok", and any other reply revises the file and sends the link again. Every brief
gets a spec but four, named by what the change touches. Cheap choices the mouse decides
itself and lists in its final report. A copy of every spec sent is kept in the main
checkout.

## The rule

1. Read the code. The choices a change holds are seldom visible in the brief; they are
   visible where the change lands.
2. Ask the whole frontier in one message: every costly choice whose prerequisites are
   settled, each with a recommended answer. Each round costs the person a full round
   trip, so a round never asks one question at a time. Answers can open another round,
   and every round ends on the status marker. A round with nothing in it is not sent.
3. Write the spec and send a link to it, whether or not a round went first. The question
   reads "Review spec here: [<title>](file://…/.whiska-spec.md)" and "ok to build?", with
   no spec text; the link
   names the worktree's own file, so it works for the review, before the build. The
   person opens the file; `whiska questions <id>` shows the link line as written.
4. Build to it. A costly choice found mid-build is a real decision and stops the mouse
   the same way; it is never a quiet edit to the spec.

A mouse never asks what the brief already spells out. A mouse sends no plan; the oks it
waits for are on its costly choices and on its spec. The plan binds the main session only
(ADR-0081).

A "done" or failing test that needs a guess is itself a costly choice, since building
the wrong thing is the most expensive thing to undo. Before writing code a mouse names
"done" and the failing test, and picks that test itself (ADR-0085).

## Four briefs skip the spec

Every brief gets a spec except these, and they skip grilling too:

- a typo, or a comment or doc no program reads;
- a formatting or lint fix;
- a test-only change, which leaves the code it tests alone;
- a brief that spells out the exact change: "rename `foo` to `bar`", "set the timeout to
  30s". There the person's own words are the spec.

The four are judged by what the change touches, never by its size or by whether the mouse
sees a choice. A brief naming a symptom, "fix the 500", spells out no change. A change
that hides, drops or skips anything is never one of the four, and doubt means a spec.
Neither is one that touches secrets, access or a security check, however small: a typo
in a role name or one address added to an allow-list widens access in a line. A
mouse with nothing costly to ask goes straight to the spec, whose decisions name each
choice it made beside the alternative it passed over, so the person overrules it there.

The version before this skipped grilling and the spec whenever no costly choice was open.
In another repo a mouse fixed a 500 by filtering activities out of an API response: it saw
one way to fix a crash, so no choice, so no grilling and no spec. The filter dropped
activities users see, which was the person's call, and with no spec the cold review had
nothing to hold the behaviour against (ADR-0049). Whether a choice exists was the mouse's
judgement, and that judgement is what failed; the four are named by what the diff touches
instead, and the spec's What Changes for Users section makes the mouse write down what
disappears.

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
words: at most ten stories about the person's users, one line per choice naming the
alternative passed over and citing its ADR, and anything beyond the brief as one line
under Out of Scope. The first ten real specs ran 986 to 3,463 words, were approved
unchanged, and held stories whose actor was a mouse, docs upkeep and byte-level detail;
nobody reads that. A What Changes for Users section is never left out: every behaviour a
user or a calling program sees differently, anything hidden, dropped, skipped or turned
from an error into silence included, or "Nothing." The finish pipeline's first step reads
the work back against the spec, beside the brief, and its report holds each behaviour
change against it (ADR-0049).

The spec is a file git ignores, never committed. Untracked is not enough: the owl takes a
landed worktree down only when `git status --porcelain` reads clean (ADR-0061). So
`whiska shape` and `whiska mode` add `/.whiska-spec.md` to the main checkout's
`.git/info/exclude`, which every worktree of the repo reads and which is never committed
(ADR-0056). That write is Whiska's own process; a mouse never edits the main checkout
(ADR-0013), so the skill only checks `git check-ignore` and, if the line is missing, says
so in one line under the spec. A session working in the main checkout adds the line
itself.

Whiska ships `whiska-spec` and `grilling` from `priv/skills/`, in both scopes (ADR-0056),
so each has one copy. The mouse's rules point at both by name, as they do at `whiska-finish`.
The skill walks the design tree in rounds, each asking the whole frontier with a
recommended answer; the rules scope it: only the costly choices are asked, and the cheap
ones are decided and listed in the report. A mouse's round ends with the decision marker.
A sniff mouse grills the research question only (goal, the decision it feeds, scope,
depth, what to deliver) and skips that when the brief answers it; it never grills design,
since the research settles facts. A build started from a **Proposed build** takes its
Found as fact, asks its Open choices, and still grills the design of the build.

## Every spec sent is kept

`git worktree remove` deletes ignored files, and a dropped branch has no commits to hold
the outcome. So every spec a mouse sends is kept in `.whiska/specs/` in the main
checkout, one file per spec, named `<date first written>-<branch, with / as ->.md`; a
second mouse on the same branch name the same day gets `-2`. A header says the repo,
branch and mouse, the question it was last sent as, the questions earlier revisions were
sent as (`replaced:`), when it was written, and its status: `waiting`, `landed <date>,
branch head <commit>` or `dropped <date>`. A revision overwrites its file, and review
comments on the earlier text go with it. The question holds only a link, so an earlier
revision is not readable afterwards; the copy is history, not what the person reviews.

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

- **Always send a grilling round**, even one saying "nothing to decide": a second round
  trip before code on every task, when the spec already carries the choices made. Its
  other half, a spec on every task, is now the rule.
- **Nothing skips the spec**: a round trip on every typo.
- **Keep "no costly choice, no spec" and widen "costly"**: still rests on the mouse
  spotting the choice, which is what failed.
- **Leave "costly" to judgment**: every mouse draws the line in a different place.
- **Ask every choice, cheap ones included**: buries the two that matter under ten that
  do not, and the person stops reading.
- **Build straight from the grilling answers**, no spec: costs no round trip, but the
  person's ok was on choices one at a time, never on the whole. They chose to read the
  whole spec, through its link, before any code.
- **Commit the spec on the branch**: durable and reviewed, but teammates see the file in
  every repo Whiska is installed in. **The repo's issue tracker**: setup per repo, and it
  publishes outside the machine. **Only the question**: nothing for finishing to read
  back.
- **Copy the spec at worktree removal**: the sweep, `drop-worktree` and Land here would
  each have to remember, and a worktree removed by hand would still lose it. **The mouse
  copies it**: a mouse never writes to the main checkout.
- **A folder per branch with one file per revision**: specs are overwritten anyway.
- **Paste the whole spec into the question**: the first version; the person reads the
  file by its link instead, and the question stays one line.
- **Link to the kept copy in the main checkout**: it outlives the worktree, but the owl
  writes it after the question is sent, so the mouse cannot name its file without a new
  command or a placeholder the owl rewrites. The link is only needed during the review.

## Consequences

A task with a costly choice costs two round trips before any code, one on the costly
choices and one on the spec; any other task costs one, the spec, and the four that skip it
cost none. A crash fix nobody had a choice about now waits on the person. The final report grows by the
cheap choices made, each a line under what changed, outside the report's size cap. A
doorstep entry carries an optional `spec` field; an entry without one still decodes. A
house without a herdr socket leaves every kept spec at `waiting`. `.whiska-mouse` had the
same untracked-file problem, and is hidden the same way, by the owl when it opens the
house (ADR-0002).

The link names the worktree's file, so an answer given after the worktree is gone finds a
dead link; the text is then in the kept copy, whose `question:` header names the question.

Folded in on 2026-10-08: 0076, 0085 (their text is in git history).
