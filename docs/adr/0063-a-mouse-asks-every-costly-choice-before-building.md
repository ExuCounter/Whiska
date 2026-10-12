# A mouse writes a spec and a build plan, or for a bug a research document, and builds on the person's ok

A mouse reads the code first, then sends one message listing every choice that has real
alternatives and is costly to undo, each with the answer it recommends, and waits for the
person's ok; with nothing costly to ask it sends no such message. After the last round, or
straight away, it runs `whiska-spec` and `whiska-plan`, which write the spec to
`.whiska-spec.md` and the build plan to `.whiska-plan.md` at the worktree root and send
links to both as one question; the mouse builds only when the person replies "ok", and
any other reply revises the files and sends the links again. A bug skips grilling and the
spec: `whiska-research` reproduces it in a failing test and writes a research document,
and the build plan goes with it, or after the person's pick when there is a choice. Every brief gets a spec or a research
document but four, named by what the change touches. Cheap choices the mouse decides
itself and lists in its final report. A copy of every spec and build plan sent is kept in
the main checkout.

## The rule

1. Read the code. The choices a change holds are seldom visible in the brief; they are
   visible where the change lands.
2. Ask the whole frontier in one message: every costly choice whose prerequisites are
   settled, each with a recommended answer. Each round costs the person a full round
   trip, so a round never asks one question at a time. Answers can open another round,
   and every round ends on the status marker. A round with nothing in it is not sent.
3. Write the spec and the build plan and send links to both, whether or not a round went
   first. The question reads "Review spec here: [<title>](<link>)", then "Review build
   plan here: [<title>](<link>)", and "ok to build?", with no text of either; the lines
   come from `whiska spec-link`, one per document the worktree holds, and each link names
   the worktree's own file as `file://…`, so it works for the review, before the build,
   or the viewer the person's `WHISKA_SPEC_LINK` names (ADR-0085). The person opens the
   files; `whiska questions <id>` shows the link lines as written.
4. Build to both. A costly choice found mid-build is a real decision and stops the mouse
   the same way, and so is a costly change to the build plan; neither is a quiet edit to
   a file.

A mouse never asks what the brief already spells out. The oks it waits for are on its
costly choices and on its spec and build plan. The main session's own 2–4 line plan
before work it does in place is a different thing (ADR-0081).

## The build plan

The spec says what the change does for the person's users; it never showed how the code
would be built, so the person first saw the approach in the diff, and on a big change a
wrong approach cost a rebuild. The build plan is that approach, written the way a senior
engineer would before starting: where the change lives in the system, the interfaces,
file formats and stored data it adds or changes, how it will be tested, and the approach
turned down and why. It is the shape of the change, not a step-by-step plan.

- **Every brief that gets a spec gets one**: a few lines for a small change, one screen at
  most. It is not kept for big changes, since whether a change is big is the mouse's
  judgement, the kind of judgement the four skips below stopped resting on.
- **Text.** Code only for interfaces (signatures, command flags), data shapes (a column, a
  JSON field, a file format, a 3 to 5 line example) and output the user sees; never
  function bodies or step-by-step code. A diagram only when the change moves data across
  three or more parts.
- **The spec gives up what moved there**: test seams, the first failing test, where the
  code lives, internal interfaces and the rejected approach. The spec keeps behaviour and
  the choices a user or a calling program sees.
- **A separate file**, `.whiska-plan.md`, ignored like the spec. The cold review holds
  the diff against the spec and the repo's decisions and never reads the build plan
  (ADR-0049): a reviewer handed the builder's plan judges the diff against it, which is
  the briefing a cold review exists to avoid. Neither the spec nor the research document
  names it.

## A bug gets a research document, not a spec

A bug, something working wrong whose fix changes nothing beyond it, needs proof of the
cause and the fix options more than user stories. So it skips grilling and the spec and
runs `whiska-research`:

1. Reproduce it with a failing test first. The test is the evidence of the cause.
2. Write the research document, `.whiska-research.md`: before and after, the root cause,
   what else the fix affects, and fix options with their trade-offs and a recommendation
   only when there is a real choice. One obvious fix is the cause, the fix and the test.
3. One obvious fix: the research document and the build plan go in one question. A real
   choice: the research document goes alone, the mouse writes the person's pick into it,
   then sends the build plan for its own ok. Then it builds.

A fix that changes behaviour beyond the bug goes the feature way, with grilling and a
spec: "what else the fix affects" is where the mouse has to write that down. A bug it
cannot reproduce stops the mouse with the research document, what it tried and no fix,
since a fix for a guessed cause is the guess this record calls costly. The cold review
holds the fix against the research document's before and after and the option picked
(ADR-0049).

The research document is the one an investigation already leaves (ADR-0074), with the
sections for a bug switched on: one template, its sections chosen by the kind of work.

A "done" or failing test that needs a guess is itself a costly choice, since building
the wrong thing is the most expensive thing to undo. Before writing code a mouse names
"done" and the failing test, and picks that test itself (ADR-0085).

## Four briefs skip the spec

Every brief gets a spec, or for a bug a research document, except these, and they skip
grilling too:

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

`whiska-spec` keeps the person's template headings, but for the two that moved to the
build plan, and asks for one screen, about 500 words: at most ten stories about the
person's users, one line per choice naming the alternative passed over and citing its
ADR, and anything beyond the brief as one line under Out of Scope. The first ten real specs ran 986 to 3,463 words, were approved
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

Whiska ships `whiska-spec`, `whiska-plan`, `whiska-research` and `grilling` from
`priv/skills/`, in both scopes (ADR-0056), so each has one copy. The mouse's rules point at
each by name, as they do at `whiska-finish`. The build plan and the research document are
ignored the same way as the spec: `whiska shape`, `whiska mode` and the owl's house
opening add their lines to the exclude file.
The skill walks the design tree in rounds, each asking the whole frontier with a
recommended answer; the rules scope it: only the costly choices are asked, and the cheap
ones are decided and listed in the report. A mouse's round ends with the decision marker.
A sniff mouse grills the research question only (goal, the decision it feeds, scope,
depth, what to deliver) and skips that when the brief answers it; it never grills design,
since the research settles facts. A build started from a **Proposed build** takes its
Found as fact, asks its Open choices, and still grills the design of the build.

## Every spec and build plan sent is kept

`git worktree remove` deletes ignored files, and a dropped branch has no commits to hold
the outcome. So every spec a mouse sends is kept in `.whiska/specs/` in the main
checkout, one file per spec, named `<date first written>-<branch, with / as ->.md`; a
second mouse on the same branch name the same day gets `-2`. A header says the repo,
branch and mouse, the question it was last sent as, the questions earlier revisions were
sent as (`replaced:`), when it was written, and its status: `waiting`, `landed <date>,
branch head <commit>` or `dropped <date>`. A revision overwrites its file, and review
comments on the earlier text go with it. The question holds only a link, so an earlier
revision is not readable afterwards; the copy is history, not what the person reviews.

A build plan is kept the same way beside its spec, as `<the spec's file name>.plan.md`,
with the same header and the same landed or dropped status; with no spec, as for a bug, it
takes the date and branch name itself. Only a new or revised spec marks its question as a
spec sent. A research document is kept per question in `.whiska/research/<id>.md`, as
ADR-0074 keeps an investigation's.

The copy is taken when the spec is sent. The `Stop` hook reads the worktree's spec, research
document and build plan into the doorstep entry beside the message (ADR-0036), and the owl writes the copy when it
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

- **No build plan, as before**: the person sees the approach only in the diff, after the
  build it would have saved.
- **A build plan only for a big change**: rests on the mouse judging size.
- **The approach inside the spec**: the cold review reads the spec, so it would read the
  builder's plan too, and a section marked "not for the reviewer" rests on the reviewer
  obeying a marker inside the text.
- **A step-by-step plan**: what the person asked not to get; the steps change as the code
  is read, and they are the mouse's to choose.
- **A separate `whiska plan-link` command**: a second command a mouse can forget to run.
  `whiska spec-link` prints a line per document present.
- **A spec for a bug, as for a feature**: user stories about a fix restate the bug, and
  nothing asks for the evidence of the cause.
- **A bug-only document beside an investigation's**: two templates for the same kind of
  work, finding out before building.
- **Always two rounds for a bug**, research document then build plan: a round trip with
  nothing to pick when the fix is obvious.

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
choices and one on the spec and build plan; any other task costs one, and the four that
skip it cost none. A bug costs one when its fix is obvious and two when there is a
choice. A spec's question for an ok carries two links. A crash fix nobody had a choice about now waits on the person. The final report grows by the
cheap choices made, each a line under what changed, outside the report's size cap. A
doorstep entry carries optional `spec`, `research` and `plan` fields; an entry without
them still decodes. A
house without a herdr socket leaves every kept spec at `waiting`. `.whiska-mouse` had the
same untracked-file problem, and is hidden the same way, by the owl when it opens the
house (ADR-0002).

The link names the worktree's file, so an answer given after the worktree is gone finds a
dead link; the text is then in the kept copy, whose `question:` header names the question.

Changed on 2026-10-12: a build plan beside the spec, and a research document for a bug.

Folded in on 2026-10-08: 0076, 0085 (their text is in git history).
