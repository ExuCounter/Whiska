# A mouse writes a spec and a build plan, or for a bug a research document, and builds on the person's ok

A mouse reads the code first, then sends one message listing every choice that has real
alternatives and is costly to undo, each with the answer it recommends, and waits for the
person's ok; with nothing costly to ask it sends no such message. After the last round, or
straight away, it writes the spec to `.whiska-spec.md` and the build plan to
`.whiska-plan.md` at the worktree root and asks for an ok on both as one question, which
`whiska show` links; the mouse builds only when the person says ok, and any other reply
revises the files and asks again. A bug skips grilling and the spec: the mouse reproduces
it in a failing test and writes a research document, and the build plan goes with it, or
after the person's pick when there is a choice. Every task gets a spec or a research
document but four, named by what the change touches. Cheap choices the mouse decides
itself and lists in its final report. A copy of every spec and build plan sent is kept in
the main checkout.

## The rule

1. Read the code. The choices a change holds are seldom visible in the task; they are
   visible where the change lands.
2. Ask the whole frontier in one message: every costly choice whose prerequisites are
   settled, each with a recommended answer. Each round costs the person a full round
   trip, so a round never asks one question at a time. Answers can open another round,
   and every round ends on the status marker. A round with nothing in it is not sent.
3. Write the spec and the build plan and ask "ok to build?", whether or not a round went
   first, with no text of either and no link: `whiska show` adds `Spec` and
   `Build plan` links on the row under the heading, one per document the mouse's worktree
   holds, as it adds the diff's and the research document's (ADR-0074), and only while
   the question is not finished (ADR-0089). Each link names the worktree's own file as `file://…`,
   so it works for the review, before the build, or the viewer the person's
   `WHISKA_SPEC_LINK` names (ADR-0085). The person opens the files.
4. Build to both. A costly choice found mid-build is a real decision and stops the mouse
   the same way, and so is a costly change to the build plan; neither is a quiet edit to
   a file.

A mouse never asks what the task already spells out. The oks it waits for are on its
costly choices and on its spec and build plan. The main session's own 2–4 line plan
before work it does in place is a different thing (ADR-0088).

## The build plan

The spec says what the change does for the person's users; it never showed how the code
would be built, so the person first saw the approach in the diff, and on a big change a
wrong approach cost a rebuild. The build plan is that approach, written the way a senior
engineer would before starting: where the change lives in the system, the interfaces,
file formats and stored data it adds or changes, the first failing test, and the approach
turned down and why, unless the spec or research document already names it. It is the
shape of the change, not a step-by-step plan: where it lands is one line per module,
never a list of the docs, comments or tests it touches.

- **Every task that gets a spec gets one**: a few lines for a small change, one screen at
  most. It is not kept for big changes, since whether a change is big is the mouse's
  judgement, the kind of judgement the four skips below stopped resting on.
- **Text.** Code only for interfaces (signatures, command flags), data shapes (a column, a
  JSON field, a file format, a 3 to 5 line example) and output the user sees; never
  function bodies or step-by-step code. A diagram only when the change moves data across
  three or more parts.
- **The spec gives up what moved there**: test seams, the first failing test, where the
  code lives, internal interfaces and an approach turned down that no user sees. The spec
  keeps behaviour, the limits the task and the person set, and the choices a user or a
  calling program sees.
- **A separate file**, `.whiska-plan.md`, ignored like the spec. The cold review holds
  the diff against the spec and the repo's decisions and never reads the build plan
  (ADR-0049): a reviewer handed the builder's plan judges the diff against it, which is
  the shaping a cold review exists to avoid. Neither the spec nor the research document
  names it.

## A bug gets a research document, not a spec

A bug, something working wrong whose fix changes nothing beyond it, needs proof of the
cause and the fix options more than user stories. So it skips grilling and the spec, and
the build brief's steps for a bug run instead:

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
sections for a bug in place of an investigation's: the build brief carries a bug's, the
sniff brief an investigation's.

A "done" or failing test that needs a guess is itself a costly choice, since building
the wrong thing is the most expensive thing to undo. Before writing code a mouse names
"done" and the failing test, and picks that test itself (ADR-0085).

## Four tasks skip the spec

Every task gets a spec, or for a bug a research document, except these, and they skip
grilling too:

- a typo, or a comment or doc no program reads;
- a formatting or lint fix;
- a test-only change, which leaves the code it tests alone;
- a task that spells out the exact change: "rename `foo` to `bar`", "set the timeout to
  30s". There the person's own words are the spec.

The four are judged by what the change touches, never by its size or by whether the mouse
sees a choice. A task naming a symptom, "fix the 500", spells out no change. A change
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

The spec has a title and up to four headings — the problem, what changes for users, the
decisions, what is out of scope — on one screen, and each fact appears once across the
spec, the build plan and the research document; no section repeats another, and none
lists docs updated to match. The problem is why, in two lines at most, with what the task
did not say. The decisions are the choices the mouse made itself, and each ADR whose
decision changes, one line each naming the alternative passed over. The person's
grilling answers, and the limits the task sets, appear once under what changes, as
behaviour or as a limit (a dependency, an approach, a secret never logged), so the cold
review, which reads neither the task nor the plan, still holds the diff against them. Out
of scope holds only what the task could be read to include. A heading with nothing under
it is left out, but what changes for users. The first ten real specs ran 986 to 3,463
words, were approved unchanged, and held stories whose actor was a mouse, docs upkeep and
byte-level detail; nobody reads that. With four headings, the last three before
2026-10-14 still ran 650 to 1,100 words with their plans, much of it the task, the
person's answers or another section retold. A line cap was turned down: a needed line is
never cut to fit, and a repeat is the thing to cut. What changes for users
is never left out: every behaviour a user or a calling program sees differently, anything
hidden, dropped, skipped or turned from an error into silence included, or "Nothing."
Finishing reads the change back against the spec (ADR-0049).

The spec is a file git ignores, never committed. Untracked is not enough: the owl takes a
landed worktree down only when `git status --porcelain` reads clean (ADR-0061). So
`whiska shape` and `whiska mode` add `/.whiska-spec.md` to the main checkout's
`.git/info/exclude`, which every worktree of the repo reads and which is never committed
(ADR-0056). That write is Whiska's own process; a mouse never edits the main checkout
(ADR-0013), and its brief tells it only that these files are ignored and never to commit
or delete them. The build plan, the research document and the mouse's own brief are
ignored the same way: `whiska shape`, `whiska mode` and the owl's house opening add their
lines to the exclude file.

Grilling, the spec, the build plan and the research document are a few lines each of the
build brief, and the research document and its questions of the sniff brief
(ADR-0088). Grilling goes in rounds, each asking the whole frontier,
numbered, each with the answer the mouse recommends, and the person answers in their own
words; only the costly choices are asked, and the cheap ones are decided and listed in
the report. A mouse's round ends with the decision marker. A sniff mouse asks only when
the goal, scope or the decision it feeds is unclear, and never grills design, since the
research settles facts. A build started from a **What to change** takes its findings as
fact, and still grills its open choices and the design of the build (ADR-0074).

## Every spec, build plan and research document sent is kept

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
spec sent. A research document is kept the same way, as `<the same name>.research.md`,
with the same header and status, and so is a mouse's report, as `<the same name>.report.md`
(ADR-0089); neither marks its question as a spec sent. A new file
of any of the four takes the name of one already kept for its mouse, so they sit side by
side. The research copy is what `whiska show` links (ADR-0074), so one file per branch,
overwritten each round, is what makes an earlier question's link open the latest text.

The copy is taken when the spec is sent. The `Stop` hook reads the worktree's spec, research
document and build plan into the doorstep entry beside the message (ADR-0036), and the owl writes the copy when it
collects the entry, naming the question just recorded. A message with a `## Summary` is a
document itself, kept from the message the same way: a sniff mouse's as its research
document, any other's as its report. An entry whose spec matches the
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
- **A link command the mouse runs**, `whiska spec-link`, pasting its lines into the
  question: a step a mouse can forget, and links made one way for the spec and plan and
  another for the diff and research document. `whiska show` adds a line per document
  present.
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
- **Copy the spec at worktree removal**: the sweep, `whiska drop` and `whiska land` would
  each have to remember, and a worktree removed by hand would still lose it. **The mouse
  copies it**: a mouse never writes to the main checkout.
- **A folder per branch with one file per revision**: specs are overwritten anyway.
- **Paste the whole spec into the question**: the first version; the person reads the
  file by its link instead, and the question stays one line.
- **Link to the kept copy in the main checkout**, as the research document is: it
  outlives the worktree, but the link is only needed during the review, and the
  worktree's file is the one the mouse revises.

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

Changed on 2026-10-14: each fact appears once across the spec, build plan and research
document; the problem is at most two lines, the decisions are the mouse's own, the
person's answers and the task's limits sit under what changes, an empty heading is left
out, and the plan names one line per module and the first failing test.

Changed on 2026-10-13: a mouse's report and a sniff mouse's research document are its
final message, kept beside the spec (ADR-0089).

Changed on 2026-10-13: the spec, build plan, research document and grilling are sections
of the briefs, not skills; `whiska show` links the spec and build plan, and the mouse
pastes no link; the spec has four headings and no user stories
(ADR-0088).

Changed on 2026-10-12: a build plan beside the spec, and a research document for a bug.

Changed on 2026-10-12: the research document is kept beside the spec, one file per
branch, not one per question in `.whiska/research/`: the person opened an earlier
question's link, commented, and found their comments on a copy a later round had already
replaced. Earlier rounds are not kept, as for specs.

Folded in on 2026-10-08: 0076, 0085 (their text is in git history).
