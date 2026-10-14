# Whiska

An Elixir/OTP coordinator that manages Claude Code worker sessions running in isolated
git worktrees, replacing this repo's bash-based worktree-notification relay.

## Language

**Whiska**:
The per-project coordinating presence a person controls directly — their main Claude
Code session for a project, backed by that project's own house in the shared owl. Counted
as one only while that house is open (in the open-houses record) and a live session sits
in the project's main checkout; a repo with a house on disk but no owl keeping it is not
a whiska, however live its session.
_Avoid_: instance, coordinator

**Mouse**:
A running herdr pane + Claude Code session working inside its own isolated git
worktree, spawned and supervised by a Whiska.
_Avoid_: worker, crewmate, agent

**Base**:
The branch a mouse's worktree was cut from: the branch the main checkout was on when
`whiska shape` ran, kept in the mouse's record. Its commits are measured beyond it, and
its work has landed when it reaches it, here or in the **fetched base** (ADR-0061). A
mouse with none recorded is read against the repo's default branch; a recorded one that is
gone is unknown, never the default.
_Avoid_: main, trunk, target

**Fetched base**:
The copy of a **base** last fetched from its remote: where a **merge request** merged on
the forge shows before anyone pulls. Work it holds has landed as surely as work the base
here holds. The owl fetches it while a merge request waits, and a fetch the person runs
moves it too; it is only as fresh as its last fetch, and it never moves the local base branch
(ADR-0087).
_Avoid_: remote base, upstream (git's word for what a branch pushes to and pulls from)

**Brief**:
Everything Whiska tells a session, in one file Claude Code is started with
(`--append-system-prompt-file`), so it sits in the system prompt for the whole session.
The main session's is `main.md`, written into the house by `whiska start`; a mouse's is
its mode's, `build.md` or `sniff.md`, written by `whiska shape` to `.whiska-brief.md` at
the worktree root, which git ignores; its **task** is not in it. Nothing else carries
Whiska's words into a session: no start-up hook, no skill, nothing in a `CLAUDE.md`
(ADR-0088).
_Avoid_: rules, skill, system prompt (Claude Code's own, which a brief is appended to),
instructions

**Task**:
What a mouse is given to build or find out — the person's own words, written to a file and
handed over by `whiska spawn` or `whiska send`, or a **proposal** the person said to
build, handed over by its question id alone (`whiska spawn --from`). `whiska spawn` types
it as the mouse's first prompt; `whiska send` hands one to a mouse at work as a file. A
task is **buildable** once its **spec** and **build plan** have the person's ok, or for a
bug its **research document** and build plan, and before that no **costly choice** in it
may be left open, "done" and the failing test that proves it included; an open one gets
grilled, after the mouse has read the code and before it writes any (ADR-0063). One of
the four tasks that skip the spec is buildable as it stands: its words are its spec.
_Avoid_: brief (the rules the mouse starts with), ticket

**Grilling**:
The rounds of questions a mouse asks before building a task that is not yet buildable:
every costly choice still open, numbered, each with the answer the mouse recommends, then
a wait for the person, who answers in their own words. A round asks the whole frontier —
every question whose prerequisites are already settled — in one message, because each
round costs the person a full round trip. A sniff mouse asks only when the goal, the scope
or the decision it feeds is unclear, and never grills design. With nothing costly to ask, no round is sent
and the mouse goes straight to its spec. A bug gets no round: the fix options in its
**research document** are its questions.
_Avoid_: interview, clarification

**Costly choice**:
A choice in a task that has real alternatives and is costly to undo: something outside
the change depends on it — a file format, a command-line flag or interface, stored data, a
dependency added or dropped, behaviour the person would notice — or it touches secrets,
access or a security check, or the rest of the change is built on it. A mouse asks these
before building. Every other choice is **cheap**: the mouse decides it and lists it in its
final report, and in the spec beside the alternative it passed over when it had a real
one (ADR-0063).
_Avoid_: big decision, one-way door

**Spec**:
A task, written down on one screen: why, in two lines at most; what changes for users,
the person's answers and the task's limits included; the choices the mouse made itself,
and each ADR whose decision changes; and what is out of scope when the task could be read
to include it. Each fact once, no section repeating another, in
`.whiska-spec.md` at the worktree root, which git ignores. How it is built is in its
**build plan**, never here.
The mouse writes it after the last grilling round, or with no round when nothing costly
was open, asks for the person's ok on it and its build plan as one question, and builds
only on that ok. `whiska show` links both, `Spec:` and `Build plan:` (the person opens the
files, wherever their `.md` files open, such as annotate; the question holds no spec text
and no link). What changes for users is never left out: anything hidden, dropped, skipped
or turned from an error into silence included, or "Nothing." Every task gets one but a bug, which gets a
**research document**, and four named by what the change touches: a typo or a comment or
doc no program reads, a formatting or lint fix, a test-only change, and a task that spells
out the exact change, whose words are its spec. A change that hides, drops or skips anything, or touches secrets, access or a
security check, is never one of the four. A task's size never skips it, and neither does
having nothing to grill (ADR-0063). A copy of every spec sent is kept in `.whiska/specs/` in the main checkout,
named by date and branch, with a header saying its question and whether the branch
landed or was dropped (ADR-0063).
_Avoid_: plan, design doc, ticket

**Build plan**:
How a change will be built, as a senior engineer would put it before starting: where it
lives in the system, one line per module, the interfaces, file formats and stored data it
adds or changes, the first failing test, and the approach turned down and why unless the
spec or research document names it. The shape of the change, never a step-by-step plan
or a list of the docs, comments and tests it touches: text, with code only for
interfaces, data shapes and output the user sees, and a diagram only when data moves
across three or more parts; a few lines for a small change, one screen at most. In
`.whiska-plan.md` at the worktree root, which git ignores, written beside every spec, or
for a bug beside its research document or after the person's pick, and approved with it.
The cold review never reads it (ADR-0049), so the diff is judged against what the person
wanted, not against the plan; neither the spec nor the research document names it. A
costly change to it mid-build is a decision for the person. Kept beside its spec in
`.whiska/specs/` (ADR-0063). Not the main session's 2–4 line plan before work it does in
place.
_Avoid_: plan (bare), design, design doc, implementation plan

**Mouse record**:
Whiska's own persisted row tracking a mouse — its pane, worktree path, branch label,
and shape — keyed by `mouse_id`. Outlives the mouse itself: a dead mouse still has a
mouse record, marked dead rather than deleted, and a mouse whose worktree has been cleaned
up is marked removed and left there, permanently inert. A record is **stale** when it no longer
stands for a worktree of this house — a record made later covers the same folder, or one
of the worktrees nested inside its folder. A stale record is nobody's mouse: it is never
matched to a pane, and neither `whiska mice` nor the board has a row for it, so it has
no **sidebar line** either. This sense
of **stale** is about a record standing for the wrong thing; the other sense, a process
running an older version of itself, is **running old** — see that entry.
_Avoid_: Mouse (bare) when the distinction between the live session and the tracking
row actually matters

**mouse_id**:
The one stable identity for a mouse — an opaque id minted once and written to a hidden
marker file at the worktree's root when the mouse is created. Never the branch name or
folder path; both of those can change without the mouse_id changing.

**Start directory**:
The directory a Claude Code session was started in, read from the first entry of its own
transcript. Which session a hook is firing in — which mouse, or none — is derived from
this and from the pane it runs in, and never from the working directory the hook is
handed: that one follows every `cd` the session runs, so a main session that stepped into
a worktree read as that branch's mouse and a mouse that stepped out read as nobody
(ADR-0053). A start directory under `worktrees/` that is no checkout of its own — the
ordinary folder a slashed branch nests under — is **nobody**: no mouse, no mode, no
marker (ADR-0030).
_Avoid_: cwd, working directory (both name the thing that moves)

**Nested session**:
A Claude Code session whose `claude` process runs underneath another `claude`, such as
a test script or a `claude -p` a mouse starts in its own worktree. It starts where the
mouse started and runs in the mouse's pane, so neither the start directory nor the pane
tells it apart. The process tree does. It speaks for nobody: nothing it ends a turn with
reaches the doorstep, and it is handed no answer. It is still
stopped by the **hold** on the mouse whose worktree it runs in, but starts without that
mouse's **deny list** (ADR-0084).
_Avoid_: child session, subsession (a subagent is neither, and is no session of its own)

**Question**:
A message a mouse sends when it finishes a turn. Most are real questions — they enter
the delivery queue and wait for an answer. A turn that ends with no marker at all is an
**unmarked** question: delivered like any other, recorded as having arrived unmarked. A
`done` report is told as "finished", and the person says its **finish** in place of a reply. It is
never answered: once sent it holds the delivery slot until the person writes anything in
the main session, and is closed then. A question is **open** while it waits to be told, **sent** once
delivered and waiting for its answer, then **answered** once `whiska reply` saved the
answer — which frees the slot whether or not the mouse has **taken** it yet; **superseded** when its own mouse asked a
newer one, which takes over the slot the superseded one held and goes next (ADR-0008), **closed** by hand or as a `done` report once the person wrote something after it, **settled** when its
mouse's branch landed and there is nothing left to answer to — the merge was the answer
(ADR-0064) — and **orphaned** when nothing can act on it and nothing ever answered it
(its mouse died, its worktree is gone, its record no longer stands for a worktree of this
house) with the work still not landed. An open question is **queued behind** the sent one while
another holds the slot, a `done` report included; the **sidebar line**, `whiska questions`
and the **inbox** say that — `finished · queued behind #n` for a report — and keep "waiting on
you" for the one actually sent (ADR-0082).
_Avoid_: report (as the table/record name — the word now names how a message reads,
see **Report**), event (as the table/record name)

**Report**:
The shape a mouse's final message takes — a `# ` title saying what is true now, its
**summary**, then what changed with each cheap choice made without asking, what was run
and what came back, each finding left unfixed, then the agent ledger; a question for the
person, when only they can decide, sits on the line above the marker. A sniff mouse's
report is its **research document**. It names how a message reads, never the record it
becomes: once collected the same message is a **question**. A mouse's **brief** asks for
it. Whiska keeps a build mouse's last one beside the kept **spec**, overwritten each
round, and `whiska show` links it as `Full report` and prints only its summary
(ADR-0089). `done` report is the older, narrower use of the word
— a question whose marker said `done` — and both stay.
_Avoid_: status, update, hand-off

**Summary**:
The `## Summary` section at the top of a **report** or **research document**: three to
five lines, written to be read alone. A message with one is a document, and Whiska keeps
it; `whiska show` prints the summary, and the first line of a **proposal** when there is
one, under the links, and the rest is behind them. A message with none — a question
mid-way, a mouse started before this — is printed whole (ADR-0089).
_Avoid_: gist, abstract, TL;DR, pointer (one line standing for a message, beside its marker)

**Finish**:
What becomes of a branch once its mouse is done, as the person says it in their own words
after its report: landed on the current branch (`whiska land`) by cherry-picking its own
commits, oldest first, its merges from the base skipped, then the repo's checks run, and
its worktree left to **cleanup**, which counts the copies as landed (ADR-0064); opened as
a **merge request** (`whiska pr`), which is recorded, so a later `whiska pr` pushes to it
rather than opening another; carried on by its mouse, the person's words sent to it
(`whiska send`); or dropped unmerged (`whiska drop`). Files the mouse left uncommitted
stop a landing or a merge request, named, until the person says to commit them. A
**proposal** is built by a fresh mouse (`whiska spawn --from`). Nothing is offered: the
main session shows the report and stops (ADR-0088). A finish is
never an answer — a finished question has nothing to answer.
_Avoid_: close (which a question does), disposition, land. **Cleanup** now names something
else — what becomes of the worktree after the branch has landed, not what becomes of the
branch

**Branch line**:
A finished question's `branch:` line in `whiska show`: what its branch holds
as git says when it is shown — its own commits beyond the base (the base named only when
it is not `main`), its files not committed or `clean`, or `branch unknown`; for a branch
with a recorded **merge request**, `merge request opened`, its commits no remote has yet,
and its files not committed, with a `Merge request:` line and its link under it.
Whiska's record of the branch, never the mouse's word, and what the person reads before
saying a **finish** (ADR-0074). `whiska show` prints facts, one labelled line each, and
the main brief writes the heading the person reads from them, the branch line folded in
(ADR-0089). Then one fact line per link, each there only
when it has something to open: the **diff link**, `Diff`, a link to the branch's diff,
which `whiska show` writes to one file per branch in `.whiska/reviews/`, named for the
branch with a hash of its name, as a plain `.diff` patch, so the person reviews it
from a link as they review a **spec**, in whatever their `.diff` files open in, and which
goes when Whiska deletes the branch (ADR-0085); the **research document**, `Research` (ADR-0074); the
**spec** and **build plan**, `Spec` and `Build plan`, links to the worktree's files,
only on a question that is not finished, since they are what an "ok to build?" asks
about (ADR-0063); and the **report**, `Full report` (ADR-0089).
_Avoid_: model-and-branch line (the statusline's), branch status, status line

**Merge request**:
A branch's request, on its forge, to merge into the base. Whiska knows of one only when
`whiska pr` opened it, or `whiska merge-request` recorded one opened by hand: the link is
kept on the mouse, its **branch line** says so and `whiska pr` pushes to it until it
lands, and while it waits the owl fetches the base, so its merge on the forge reaches the
**fetched base** and **cleanup** takes the worktree down. One opened elsewhere, or closed
on the forge, is not seen (ADR-0087).
_Avoid_: PR, pull request (GitHub's words; both forges are meant), review (what happens
on it)

**Proposal**:
The section of a finished investigation's **research document** when it changed nothing
and found something that should change: `## What to change`, then a Found, a Build, a Why,
a Cost and an Open line. Content, never classification — the turn still ends on `done` — so it
travels inside the question's text, where the person reads it. When they say to build
it, `whiska spawn build <branch> --from <id>` starts a fresh mouse shaped for that work
rather than flipping the one shaped for the investigation (ADR-0074). Open lists the
costly choices the investigation left; the build mouse takes Found as fact and grills Open
and the design.
_Avoid_: Proposed build (the block's older label), plan, recommendation, next steps,
hand-off (a word **Report** already rejected)

**Research document**:
What a piece of work found out before anything is built, its sections set by the kind of
work: a bug's in the build **brief**, an investigation's in the sniff brief.
- **A bug's**: `.whiska-research.md` at the worktree root, which git ignores, written
  after a failing test reproduces it — before and after, the root
  cause, what else the fix affects, and fix options with a recommendation only when there
  is a real choice, each fact once, as in the spec. It stands in for the spec: the person
  oks it or picks an option, the pick is written into it, its **build plan** follows, and
  the cold review holds the fix against it (ADR-0063).
- **An investigation's**: the sniff mouse's final message, which writes no file — its
  **summary**, its **proposal** when something should change, the question, then what it
  established, each fact once, in about two screens (ADR-0089). `whiska show` links it on
  its `Research:` line, and the person's comments on it are
  their own words, carried as a file: to the build (`whiska spawn --from <id> --comments
  <file>`), to the investigating mouse (`whiska send`), or not sent (ADR-0074).
Whiska keeps one copy per branch beside the kept **spec**, overwritten each round, so
every question's link opens the latest. First named the write-up, for investigations
alone.
_Avoid_: findings (a reviewer's word), write-up, report (the message's shape)

**Letter**:
The person's words for a mouse, copied as a file into its worktree's `.whiska-letters/`,
which git ignores: what `whiska send` hands a running mouse, and the comments
`whiska spawn --from <id> --comments <file>` hands a fresh one. Only the copy's path is
typed into the pane, never the words (ADR-0044).
_Avoid_: inbox (the person's own list of what waits on them), message (a mouse's)

**Waiting**:
Everything a house holds that still wants the person: its open and sent questions,
and the entries still sitting uncollected on its doorstep. A `done` report is waiting
until the person has been told, and a doorstep entry is waiting although no question
exists for it yet. It is a state of the house, not a status on a row: the statusline
and `whiska waiting` both ask exactly this, so the two cannot disagree about it. A house is quiet when nothing is waiting; there is no other
word for the state, and **Quiet** is that same word said of one mouse. A **held**
mouse's questions are listed by the **inbox** but are not waiting on the person — they
parked them — so neither status line counts them; a question waiting behind **away** or
a **focus** is.
_Avoid_: pending, outstanding, open (a question's own status, which is narrower), the
queue (delivery's, which a doorstep entry has not reached)

**Board**:
What every live mouse of one house is doing, as facts and no words, read once for every
place that says it: the question waiting on the person, how its pane stands with herdr —
one agent pane, none, several, or herdr not reachable — its **topic**, and its **last
action**. The topic is the short human summary of what the mouse is working on, "Order
builder for distributors", read from herdr's pane list where Claude Code keeps it as the
pane's title. The last action is the tool call it is in the middle of or the last thing it
said, read from its own Claude Code transcript and never asked for (ADR-0050), and only
when nothing about a question, a hold or its pane already decides what is said.
Its **context gauge** is how full the mouse's context is — the input, cache-read and
cache-creation tokens of the last assistant message in the transcript, `142K` — with a
five-cell bar against the window when the mouse has an auto-compact window, and the plain
size when it has none. It is read for every live mouse, whatever its line says.
A mouse is **stuck** when herdr says it is blocked, or it is working with no subagent out
and has written nothing to its transcript for two minutes while in a tool, or five while
waiting on the model (a subagent writes to its own file and the model writes nothing until
its answer arrives, so a mouse waiting on either is silent and not stuck at once). A dead mouse has no row; what it left behind
unanswered is counted apart as orphaned, never as waiting. **Sidebar lines** are written
from it, and `whiska watch` prints those. It reports and never acts (ADR-0082).
_Avoid_: dashboard, monitor, status (the line the tab bar draws), the statusline (a
surface; the board is drawn on none, only the **sidebar lines** written from it are)

**Sidebar line**:
What herdr's sidebar shows under one workspace, which the owl reports and herdr draws
(ADR-0082): under each mouse's workspace, its state — `❓ waiting on you · 14m`,
`✅ finished`, `✖ stuck 6m`, `⏳ queued`, `🎯`/`💤` waiting behind a
**focus** or **away**, `⏸ held`, `↩ picked up 2m ago`, `◐ <topic>`, `○ idle` — with the question it
carries wrapped on up to two lines beneath (a finished report's is the first line of its
`## Summary`), each carrying the mouse's **context gauge** straight after the symbol
(`❓ 142K · waiting on you · 14m`, `◐ 142K · <topic>`; a line saying the pane is lost has none); under the main checkout's workspace, what is
true of the whole repo: no **main session**, delivery **gated**, questions waiting with
no line of their own, orphans. Every line starts with a symbol only Whiska writes, which
is how the person's own herdr config colours it; a working mouse's symbol turns once a
second, so a still one means the owl has stopped. A line nobody keeps current goes away by itself, and one herdr has lost is sent
again. The mice re-sort only when one changes state, starts or stops queueing behind another, or appears in any state but idle.
_Avoid_: row (the board's; a line is what herdr draws), badge, status (the tab bar's),
the board (the facts a line is written from)

**Main session**:
The one herdr pane per house that questions are delivered to — the person's own Claude
Code session in the main checkout, recorded by `whiska start` from the pane it is run in —
which also starts Claude Code there when nothing is running in that pane yet (ADR-0066).
A house has at most one; nothing is delivered until one is recorded, and it is also where
a Jump lands. A house with none, while anything runs or waits, says so on the main
checkout's **sidebar line**; whether this pane is the one is `whiska doctor`'s to say
(ADR-0082) — a session cannot be asked which it is, so it is never guessed at
from anything but the recorded pane.
_Avoid_: primary, parent, captain

**Delivery**:
The owl typing one question's line into the main session — only when that pane is idle
and no other question is already sent. A queue, not a batch: the next question goes when
the previous one is answered (or closed, or orphaned, when its own mouse dies while
holding the slot) and the session is idle again. A question superseded while holding the
slot hands it to its mouse's newer one, which goes next ahead of every other branch's;
what the person types in the main session answers no question, so a question's slot
stays put through it. Nothing that cannot be
answered ever holds the slot: before each attempt, everything still waiting for a mouse
that is dead, or for a record that no longer stands for a worktree of this house, is
released — **settled** where its mouse's branch landed, **orphaned** where it did not
(ADR-0008, ADR-0064). Before the gate, the queue is judged against what the person set
aside (ADR-0079): nothing goes while they are
**away**, only the focused mouse's under a **focus**, never a **held** mouse's — and a
sent question of a held or unfocused mouse does not hold the slot. Oldest first, always.
While the gate holds — the session mid-turn, a
draft in its box, or no box on its screen — the queue is **gated**, and the main checkout's **sidebar line** says so once the hold has lasted
ten seconds (ADR-0082). A finished line waits for the
slot like any question, so it never lands over one the person is reading, and once the
slot is free it goes ahead of whatever is queued. Once typed it holds the slot until the
person's next prompt in the main session, whatever it says. Several go one per prompt,
each line counting how many more finished are behind it (ADR-0008).
What is typed is a one-line pointer with the id and no command; the full text is
`whiska show <id>`, which the main session's **brief** has it run when the line lands.
Delivery only ever types into the main session of the question's own house (ADR-0044);
the only other text Whiska types goes into a mouse's own pane — a **pickup**, a
**doorbell**, its **task** on `whiska spawn`, and one fixed line each on `whiska send` and
`whiska resume`. Every delivery raises a **hoot**.
_Avoid_: notify, ping, relay (the old bash mechanism), push

**Doorbell**:
The one fixed line typed into a mouse's pane when the person has answered it — "🔔 The
person answered your question #12; the answer is attached …" — and never the answer
itself (ADR-0080). Never a 🐱: that is a delivered line, which the main session's
**brief** has it read with `whiska show`. `whiska reply` rings it
once the answer is saved; the owl rings it again on the backstop while the answer is not
**taken**, at least 90 s apart and at most three times, only into an idle pane with an
empty prompt box, never a held mouse's, a landed branch's or the main session's. A
doorbell rung twice is harmless: the second finds nothing left to hand over.
_Avoid_: nudge (retired), ping, poke, inbox (the person's listing — see **Inbox**)

**Taken**:
An answer the mouse's own `UserPromptSubmit` hook has handed over: printed as context
into a prompt in that mouse's session and stamped `taken_at`, the proof it arrived. Any
prompt takes it, the doorbell or one the person types into the pane. An answer that is
`answered`, not taken, and its mouse's newest question is **chased** — the owl keeps
ringing for it. One still not taken 90 s after the owl's third ring is **not taken**: the
**sidebar line**, `inbox` and `whiska questions` say so, it counts as waiting on the person, and
one hoot goes out — once the person is back, if they are **away** or focused elsewhere.
A dead mouse's or a landed branch's answer is never not taken: nobody can act on it. A mouse that asked a newer question has moved past the answer, so it is
never chased or handed over (ADR-0005).
_Avoid_: acknowledged, acked, read, received, handled (firstmate's word, for a file a
worker moves)

**Hoot**:
The desktop notification the owl raises as it delivers a question — one per delivered
question, sent in the same breath as the line so the two can never disagree (ADR-0062).
It carries the house, the mouse's branch, the verb and the id, in the line's own words,
because the line only reaches somebody already looking at the main session and the point
of leaving a question is that they are not. A question that is only collected, or gated,
or set aside by **away**, a **focus** or a **hold**, has not hooted yet. herdr is asked to show it, from the person's own `[ui.toast]` and
`[ui.sound]` settings, and says whether it drew anything; `request` is its sound when a
decision is waiting and `done` when a branch finished. When herdr says its popups are off
or nobody is attached, the same hoot is raised on the desktop with `osascript` on macOS,
or `notify-send` on Linux, instead (ADR-0062). A hoot that fails is swallowed —
delivery is the job and the hoot is a courtesy — so `whiska doctor` is where the person
asks, by sending a hoot of its own down the same path and reporting what showed it.
_Avoid_: toast, alert, desktop notification as a term of its own (it is herdr's word for
how a hoot is shown, not for the thing)

**Gated**:
What delivery is while the gate says no and something deliverable is queued behind it:
the main session mid-turn, a draft in its box, no prompt box on its screen at all
(ADR-0047), or no main session it can reach. The question stays open and first in the
queue, and the gate holds until it lets go — one hold however its reason changes. Said in
two places in the same word: the main checkout's **sidebar line** once it has lasted ten seconds
(ADR-0082), and
`whiska doctor` whenever it is asked. Being gated is never a question's own status; it is
what delivery is doing, or not doing, to the queue. While the person is **away** the gate
is beside the point, and the line says `away` instead.
_Avoid_: held (a mouse the person put on hold — see **Held**; this entry carried that word
until 2026-10-06), blocked (a mouse's herdr status), stuck (a mouse that is not
progressing), paused, queued (every question behind the first is that anyway)

**Away**:
The person's own word for "nothing reaches me": one setting for the whole machine, a file
under the whiska home that `away` writes and `resume` removes
(ADR-0079). While it is set nothing is delivered to
any main session, no hoot is raised, mice keep working, and `inbox` keeps listing what
they ask, with `away` on its first line. Said on herdr's tab bar — `🦉 watching · away` —
and on the **sidebar line** of each mouse whose question waits behind it. Not a question's status, and not the owl's state: the owl is
watching all the while.
_Avoid_: quiet (a house with nothing waiting, or a mouse with nothing left to do), do not
disturb, muted, paused, held (a mouse's), gated (the gate's)

**Focus**:
One repo's narrowing of delivery to one mouse: the focused mouse's `mouse_id` on the
house's own row, set with `focus <branch>` and cleared by `resume`
(ADR-0079). Only that mouse's questions reach the
repo's main session; the rest wait — still listed by `inbox` and `whiska questions` as
`waits: focus on <branch>`, still counted as waiting — and a question already delivered
from another mouse no longer holds the one slot against the focused one. Per repo because
a branch is one repo's; silencing other repos is what **away** is for. A mouse whose
question waits behind it says `waits: focus on <branch>` on its **sidebar line**; the tab
bar says nothing of it.
_Avoid_: pin, filter, mute (the others are not muted, they wait), focus as herdr's word
for bringing a pane into view (see **Jump**)

**Held**:
A mouse the person put on hold with `hold <branch>`: a `held_at` stamp on its record, a
real stored status, lifted by `resume <branch>` or by a reply to one of its questions
(ADR-0079). The hook refuses its next write or
shell command — a read passes until then, or until the turn ends — with a reason that
says to end the turn here and say where it stopped
(`Whiska.Rule.Held`); the message it ends on sits in the inbox marked `held`, never
delivered, and never counted as waiting on the person — they parked it. A held mouse's
finished line is never told; it is never taken down by
cleanup (ADR-0061); never picked up (ADR-0067). Its **sidebar line** says `⏸ held`, and
`whiska mice` says `held` where herdr's status would go. The word this entry took from the gate on
2026-10-06 — see **Gated**.
_Avoid_: parked, paused, stopped (a dead turn's and herdr's word), blocked (herdr's),
gated (the gate's), on ice

**Person's command**:
A `whiska` command only the person runs, never a mouse: `away`, `hold`, `focus`,
`resume`, `reply`, `dismiss` and `close` — the ones that set or end what reaches them,
which mouse stops, and what a mouse is told — and `spawn`, `send`, `land`, `pr` and
`drop`, which start, steer, ship or throw away a branch. The main session runs them on
the person's word. Every shaped mouse's **deny list** refuses each, `whiska` in
front or bare, as a plain rule that `env` or a full path gets round (ADR-0079); a mouse
that needs one says so in its report. The reading commands — `inbox`, `show`, `questions`, `waiting`, `mice`, `ledger` — are
anyone's.
_Avoid_: admin command, privileged command (there is no privilege, only whose decision it
is), main-session command (the person may run one from any terminal)

**Inbox**:
The person's list of everything waiting on them in this repo —
`inbox`, `whiska waiting` narrowed to one repo (see **Waiting**); `inbox --all`, or `inbox`
outside any repo, reads every repo on the machine — with a last column
saying why a row is not being delivered (`held`, `away`, `focus: <branch>`, `queued
behind #n` for one waiting on the question that is out, or `not taken` for an answer its
mouse has not **taken**) and a first
line when they are away. It is a listing, not a place: a question sits in a house, an
uncollected entry on a doorstep, and the inbox reads both. `show`, `reply` and `dismiss`
act on this repo's rows only; ids repeat across repos. `show` with no id is not the inbox:
it prints only the question delivered to the person, so a queued one waits its turn
(ADR-0079).
_Avoid_: queue (delivery's), backlog, doorstep (where an entry sits before it is a
question — see that entry), waiting list (**Waiting** is the state, this is the listing)

**Unplaced**:
A directory under a house's `worktrees/` container that is no checkout of its own — the
ordinary folder a slashed branch nests under, or a worktree laid out by hand. It is
**nobody**: no mouse, no `mouse_id`, no mode, and nothing it leaves is a question.
Reading such a folder as a mouse is what minted a mouse called `quality` for `quality/QUAL-350-lnkd-emails` and let
its question wedge a queue (ADR-0030, ADR-0008).
_Avoid_: phantom mouse (it is no mouse), ghost, orphan (a question's status), the
container (the `worktrees/` folder itself, which is not this)

**Draft**:
Whatever the person has half-typed in the main session's prompt box and not yet sent. A
draft *holds* delivery — the question stays open and first in the queue — however idle
herdr says the pane is (ADR-0047): idle is the model's word, and a line typed into an
occupied box lands inside the draft or submits it. The box is the lowest **frame** on the
screen — a pair of horizontal rules at column 0 — that holds a prompt line, and the whole
of it is read, not its first line. Neither half finds it alone: the marker `❯` is also how
Claude Code redraws the person's past messages and how a picker marks its highlighted row,
and a stray rule under the box would frame the status lines (ADR-0047). A screen with **no box on it**
holds too, and for a different reason — not a draft, but nowhere for the line to land,
which is what a dialog waiting on the person looks like. A frame Whiska cannot read is no
draft, and delivers. `whiska doctor` has a line of its own for the box, because a Claude
Code that changes how it draws one would otherwise show up only as every mouse going
quiet; a pane the person has scrolled up in is reported there, not warned about.
_Avoid_: input, buffer, typing state, pending prompt

**Dead turn**:
A turn that ended without reaching the doorstep. The session did not crash — it is
sitting there idle, holding its whole context, with an error on the screen — so from
outside it looks exactly like a mouse quietly working. Read from what Whiska already
owns: the mouse was seen working, its pane has gone quiet, and nothing of its has been
collected or is waiting on the doorstep (ADR-0067). A session idle before it was ever
prompted has not had a turn die; it has not had a turn.
_Avoid_: crash (nothing crashed), hang, timeout, failed turn (it may have done most of
its work)

**Pickup**:
The owl typing one short line into a mouse's own pane to carry a dead turn on — the
"corrective nudge" the Nudge entry below left the word with. Never the original prompt:
the session still knows what it did, and re-asking risks redoing a file already written.
Waits out a settling window first, except when the mouse's transcript ends on Claude
Code's own API error, which is picked up at once (ADR-0067). One per dead turn, and a branch whose picked-up turn dies as well is a **stuck** mouse
from then on (ADR-0026), never nudged again. A mouse with a **chased** answer is never
picked up: its next turn has not begun, and the **doorbell** carries it on. One of the two
lines the owl types anywhere but its own house's main session (ADR-0044).
_Avoid_: retry, resend, restart, relaunch (ADR-0026's rung four, a different act)

**Nudge** (retired):
A line the owl used to type into *another* house's idle main session, to force that
session's statusline to redraw. Removed on 2026-09-29 (ADR-0044): the line landed as a
user turn that Claude Code could not tell from a typed prompt, so it cost that session a
turn and the model improvised on it. Nothing in Whiska now types into a session that is
not its own house's main session. The elsewhere segment it existed to refresh is gone
too (ADR-0048): the statusline is machine-wide now, so there is no elsewhere.
_Avoid_: reviving the word for anything cross-house. The one sense it keeps is the
"corrective nudge" into a *stuck mouse's own* pane, which is built and is called a
**Pickup** above (ADR-0067).

**Jump**:
Moving the person to a whiska — Whiska asking herdr to bring a house's main session into
view, so the person is sitting where they can act on what is waiting rather than looking
at a pointer to it. The one thing Whiska does to the person rather than to a mouse, and
only ever because the person asked for it in the same breath: a typed command, or a
hotkey they bound. The owl never jumps, and since the Nudge was retired it makes no
cross-house move at all. The destination is the house's main
session, never a mouse's own pane: a mouse's pane is the mouse's workplace, and the
person answers from their own (ADR-0043). A separate move, `whiska open <id|branch>`,
takes the person to one named mouse's own pane when they ask for that mouse, and no picker offers it; it is not a
jump, and the owl never makes it either (ADR-0043).
_Avoid_: goto, focus (herdr's word for the mechanism of bringing a pane into view, and
since 2026-10-06 the person's word for narrowing delivery to one mouse — see **Focus**;
neither is a jump), switch, attach, take over

**Shape**:
What a mouse is spawned as: its mode, the model it runs on and the effort it runs at,
each chosen on its own — a hard investigation is sniff on the heaviest model at the
highest effort. Given by `whiska spawn`, through `whiska shape`, before Claude starts, so
its mode's **deny list** holds from its first tool call; shaping also writes the mouse's
**brief**, and its flags start Claude with both. The spawning session picks the
model and the effort by the ordered rules in `priv/models.json`; one it leaves unnamed
is the last rule's. A build mouse also starts with an auto-compact window for its model,
from the same file; a sniff mouse keeps Claude Code's own. The record also keeps the model the mouse actually ran on, read from
its transcript. Shaping also stocks the worktree: the main checkout's `deps`, `_build` or
`node_modules`, and any path listed in the house's `clone` file, are cloned in
copy-on-write, never symlinked. There is no default mode: a mouse **never shaped** starts
with no deny list and is not limited; the person shapes it with `whiska shape` in its
worktree and restarts Claude there. A shaped mouse keeps its mode, since its model and
effort were chosen for that work: `whiska mode`, and `whiska shape` in another mode,
refuse it, pointing to What to change and a fresh mouse. The record keeps what the mouse was **shaped as** — the mode its model and
effort were chosen with — and `whiska mice` says so for a mouse flipped before that rule.
_Avoid_: profile, preset, role

**Deny list**:
The deny rules a shaped mouse starts with, in `.whiska-settings.json` at its worktree
root, which git ignores: the **person's commands** for every mouse, and `Edit`, `Write`
and `NotebookEdit` for a sniff mouse. Claude Code enforces them. The mouse runs in bypass
mode, so nothing else asks before a tool call, and the hook's one rule is the **hold**.
Written by `whiska shape` on every shape and read once, at launch, so a running mouse's
list cannot change (ADR-0090).
_Avoid_: permissions (Claude Code's whole system), allowlist (there is none), sandbox (it
is not one), guard

**Build mode**:
A mouse mode that produces a real code change, in its own worktree as its brief says. Its
**deny list** holds only the person's commands.

**Sniff mode**:
A mouse mode for investigation only. Never writes code or any file, never pushes —
produces a report instead, which is its **research document**. Its **deny list** takes
away the edit tools; its brief says the rest. Says nothing
about the model or the effort: those are chosen apart.
_Avoid_: research mode, research mouse (`research/` is the prefix a sniff mouse's branch
carries, not the mode's name)

**Owl**:
The one always-awake presence per machine, kept running by its **service manager**, that
keeps every project's house standing and is the only thing that can see across all of them
at once. Seeing is not acting: the owl reads every house, and types into none but the one
each question belongs to (see **Nudge**, retired) — and, since ADR-0067, into a mouse's
own pane when that mouse's turn died, once (see **Pickup**). Not per-project: a person has many
houses and exactly one owl.
_Avoid_: daemon, server, service

**Service manager**:
The operating system's own program that keeps the owl running: it starts it at login
and restarts it after a crash. launchd on macOS, through the user LaunchAgent
`com.whiska.owl`; systemd on Linux, through the user unit `whiska-owl.service`
(ADR-0040). `whiska owl
install|stop|start|uninstall` drive whichever is in force, and mean the same on both.
Either runs the same wrapper, `~/.whiska/owl.sh`.
_Avoid_: supervisor (OTP's word, for the process tree inside the owl), service (the owl
itself is not one), daemon

**House**:
One project's permanent home — its own database, its own mouse records, its own
identity — isolated from every other project's. A house exists from the first
`whiska start` in a repo onwards; it is never destroyed by stopping.
_Avoid_: subtree (means a git subtree and an OTP supervision subtree — both wrong
here), slice, partition

**Open house / shut house**:
Whether the owl is currently keeping a house's lights on. `whiska start` opens a house —
its socket starts listening, it subscribes to herdr, collection begins, and it gets its own
supervision inside the owl. `whiska stop` shuts it: socket closed, collection stopped,
supervision dropped. The house itself, its database and its mouse records, is untouched
either way.
_Avoid_: creating/destroying, starting/tearing down a house (those describe the house,
not its lights)

**Open-houses record**:
The owl's note to itself of which houses it has open, kept outside any one house: a
house is added when opened, removed when shut, and the note is left alone when the whole
owl stops, so the next `whiska owl` reopens the same houses. Anyone else — the
statusline, the doctor — trusts it only while an owl is running. It says nothing about
whether a house exists; that is the house's own affair.
_Avoid_: registry, manifest, house list (it lists open houses, not houses)

**Owl socket**:
The owl's read-only Unix socket, `~/.whiska/owl.sock` (ADR-0033): one request line in —
`waiting`, `show <id> <main_checkout>`, `jump`, `questions <main_checkout>`, `line [hint]` — one line out. It is what the
person's own scripts and herdr's tab bar ask instead of starting Whiska, its format is
documented and versioned, and it only ever reads.
_Avoid_: global socket (its name before it was built, and the hook socket is global too),
API, endpoint, server

**Hook socket**:
The owl's private Unix socket for Whiska's own hooks, `~/.whiska/hook.sock` (ADR-0033).
The hook shim sends the hook's name, its environment and its payload; the owl runs the
same hook code the escript would and answers. Anything but an answer sends the shim to
the escript, so it makes hooks fast and never makes them depend on the owl.
_Avoid_: owl socket (the read-only one), daemon socket, RPC

**Statusline**:
The line Whiska draws on herdr's tab bar, once for the whole machine (ADR-0048): the
owl's state, always, whether the person is **away**, and which whiskas have something
waiting — `🦉 watching`, `🦉 watching · away · 🐱 2 whiskas`, and `🦉 owl down` when the
owl does not answer. When something waits it ends with the key the person bound to reach
it, if they passed one to the script: `🦉 watching · 🐱 2 whiskas · ⌃a space`. A repo's
own mice are **sidebar lines**, not a statusline: Whiska draws nothing in Claude Code's
statusline, and `whiska init` takes out the one an older init wrote (ADR-0082).
_Avoid_: status bar, status line as two words (see **Worktree-status marker**), segment
(one part of it, not the line), tab bar (herdr's surface, not a name for the line
itself)

**Doorstep**:
Where a mouse leaves a question for the owl: a directory in the house, holding entries the
owl has not collected yet. Every question gets into a house through here and only through
here. The owl writes the entry when it answers the mouse's `Stop` hook over the **hook
socket**, and the escript writes the same entry when it does not, so whether the owl is
awake changes nothing about what is left (ADR-0036).
_Avoid_: spool, outbox, queue (the delivery queue is a different thing — the doorstep is
what a question sits on before it ever reaches that queue), larder, inbox (the person's
listing of everything waiting, which reads this among other things — see **Inbox**)

**In flight**:
Said of a background subagent a mouse launched and has not been handed the report of.
Claude Code ends the mouse's turn while one is out and wakes the session when it reports,
so the `Stop` hook fires on a turn that is not over: with anything in flight it writes
nothing at all, and the doorstep never hears about it (ADR-0052). Read from the mouse's
own transcript, and structurally: a `tool_result` answering an `Agent` call gives the id,
the hand-back that clears it is stamped on the entry, and a turn the person typed clears
whatever was out. Never read from what the mouse said.
_Avoid_: running, pending, busy, mid-turn (all of them describe the mouse, and it is the
subagent that is out)

**Cleanup**:
Taking a landed worktree down: the worktree removed, the mouse's pane closed with it, the
branch deleted, and the mouse record stamped removed — unattended, by the owl, on its
backstop (ADR-0061). It happens only to a **quiet** mouse whose branch has landed: the
branch merged into the base, here or in the **fetched base**, and moved off the commit it
was cut at (a sniff mouse's
worktree stays: it has nothing to merge), the worktree clean, nothing on it unpushed.
Nothing is ever
forced, and anything that cannot be established leaves the worktree exactly where it is.
The mouse record survives, as every record does (ADR-0007); only the folder, the pane and
the branch go.
_Avoid_: teardown, reaping, archiving, drop (`whiska drop` is the person's own way to
take a worktree down, which stays)

**Quiet**:
Said of a house with nothing waiting, and of a mouse with nothing left to do — the same
word, one subject down. A quiet mouse has nothing of its open or sent, nothing of its
left uncollected on the doorstep, its last word a `done` report, and no pane working in
its worktree — read from herdr's own pane list, by where each pane sits, never from the
mouse record's remembered pane. A mouse with no pane at all is quiet too: that is ADR-0026's dead
mouse. It is what cleanup waits for, and it is deliberately stricter than "nobody is
waiting on it": a mouse that never said it finished is never cleaned up after.
_Avoid_: idle (herdr's word for a pane, which is one of the four things this reads),
finished (a mouse's own claim; **Finishing** is the pipeline it runs), done (the marker)

**Running old**:
A process that is up but is serving a version older than the one on disk: the owl started
before the binary it runs was reinstalled, the installed binary built before the checkout
changed, or a Claude Code session still holding the hooks and settings it read at startup.
It is not down, so nothing fails — the change simply has no effect, and the person reads
the old behaviour as a bug in the new work. `whiska doctor` names each case against the
thing it is old relative to, and says the restart that fixes it. Distinct from a **stale**
mouse record, which is a row standing for the wrong worktree rather than an old version.
_Avoid_: stale (taken, and it means a record here), outdated, drift, out of sync

**Collection**:
The owl taking what a mouse left on the doorstep. Overwhelmingly event-driven — herdr
reports a mouse has gone idle and the owl collects that house then — with a slow timer only
as a backstop. Collection reads and marks; it never deletes and never touches the worktree.
_Avoid_: sweep (it implies tidying up, which is precisely what this must not do), poll,
drain, scan

**Usage**:
What one turn cost, as the owl records it at **collection**: one row for the mouse's own
turn, from the prompt that started it to the stop, and one per agent it sent — model,
effort, tokens by kind, steps, tool uses, seconds, API errors. Read from the transcript
the doorstep entry names, cut off at the entry's stamp, never from what the mouse said, so
a sniff mouse's turn is recorded like any other. Kept per question. A later entry for
the same turn marks the earlier rows replaced, and the rows not replaced add up.
`whiska metrics` reads it, weighing tokens into **cost units** (input + 1.25 × cache
writes + 0.1 × cache reads + 5 × output, the ratio every Claude model is priced at), since
Whiska keeps no prices (ADR-0086).
_Avoid_: ledger (the lines a finished report ends with, whose mouse line covers the whole
session), price or dollars (none is stored)

**Backstop**:
The slow timer that collects a house's doorstep when nothing else has. It is a last
resort, never a working trigger: anything it finds is something the owl should already
have been told about, so it says so rather than quietly making up the difference. How
much it has had to collect is the measure of whether the event-driven path is alive.
_Avoid_: fallback, poller, sweep, safety net (all of them suggest a path that is fine to
be on; being on this one is the symptom)

**Scope**:
Which root an install hangs off: the project (`whiska init`) or the person's home
(`whiska init --global`). Every path is the same relative path either way —
`.claude/hooks/whiska.sh` is one file in two places — so a scope is a root and nothing
else, and the merge and the idempotency are one implementation for both. Per-repo is the default and the only one that travels to someone else's machine
(ADR-0056); global is for a repo that will not carry a committed `.claude/`. Where a repo
has both, the project's copy is **in force** and the global one **stands down**: its shim
exits before doing anything, for every hook (ADR-0056).
_Avoid_: level, mode (build and sniff are modes), profile, target

**Stands down**:
What the global install does in a repo that wires Whiska itself — not "is overridden",
which would suggest something still ran. The global shim exits before resolving anything,
so for that repo it is as though it were not installed. The reason it must: Claude Code
merges the hook arrays from both files, so a hook that did not stand down would deny
twice and leave the same question on the doorstep twice.
_Avoid_: override, shadow, disable, precedence

**Worktree-status marker**:
The line a mouse ends every response with, and the only thing a turn is classified by
(ADR-0009). It is written in invisible separators (U+2063) so the person watching the
pane never sees it: three of them for `done`, two for `needs-decision`, whose readable
pointer sentence sits on the line above. `done` means the task is done: a turn that stops
short of it on purpose — a failing test written first, a mid-task answer — ends on
`needs-decision`, its question the next step. The older bracket spelling,
`[worktree-status: done]`, is still read and no longer written. The main session never
writes one. Distinct from the **marker file** that
carries a `mouse_id`: that one is identity on disk, this one is a line in a message.
Say which when either could be meant.
_Avoid_: status line (the statusline is a different thing entirely), tag, signal

**Pointer**:
One line standing in for a whole message, in two related places. A mouse's pointer is
the readable sentence it leaves beside its marker — the short question itself, or "3
questions ready, see above" — which sits on the line above a `needs-decision` marker; a
finished turn leaves none. The owl's delivery line quotes that sentence, and is itself a
pointer to the question the person reads in full with `whiska questions <id>`. Say
*the mouse's pointer* or *the delivery line* when both are in play.
_Avoid_: summary, title, subject, preview

**Finishing**:
What a build mouse does before it is allowed to say `done`: read the change back against
the spec, or a bug's research document, and the repo's written decisions; send the
**cold review**, and a security **reviewer** when the change touches input, permissions,
hooks, prompts or secrets; disprove or fix each finding, two rounds at most; commit the
work on its branch; and only then write the marker, under a **report** that gives one
line to each finding left unfixed and ends with an agent ledger: one line per agent sent,
with its tokens, then one for the mouse's own session, printed by `whiska ledger` from the
session's transcripts (ADR-0049). A section of the build **brief**, run by the mouse
itself: Whiska neither runs it nor knows whether it was run. What green means here is the
repo's to say, as a `checks:` line under a `## Finish` heading in its own `CLAUDE.md`,
which `whiska land` runs after copying a branch's commits.
_Avoid_: review loop (retired, below), checks, gate (the no-mistakes gate is a different
thing, and it runs after a push rather than at the end of a turn), CI, ralph loop

**Reviewer**:
One subagent sent over the change in **finishing**: the **cold review** always, and a
security reviewer when the change touches input, permissions, hooks, prompts or secrets
(ADR-0049). A reviewer **reports and never edits**: findings by `file:line`, no changes.
Whiska ships no agent: the mouse writes each reviewer's prompt itself, and nothing else
installed on the machine is reached for (ADR-0085).
_Avoid_: critic, auditor, linter, checker (a check is a command and a different thing), gate

**Cold review**:
The reviewer finishing always sends: a fresh one that never saw the mouse's session,
given the diff from `whiska base`, the spec or research document, and the repo's decisions
as they stood at the base — never the build plan, so the diff is judged against what the
person wanted rather than how the builder chose to build (ADR-0049).
_Avoid_: correctness reviewer (what it replaced), second opinion


**Review loop** (retired):
`.claude/hooks/review-loop.sh`, a `Stop` hook the repo owned, which blocked a turn ending
on `done` until a single `CHECK` command passed and the mouse had read its own diff back
once. Superseded by **Finishing** (ADR-0049): one check command could not know what green
means in a given repo, and a shell script could make no judgment at all. Nothing writes
it, chains it or runs it. A file still on disk is inert, `whiska doctor` says so, and
Whiska never deletes it (ADR-0007). Named here because repos still have the file and the
word is still in old handoffs; do not reach for it for anything current.
