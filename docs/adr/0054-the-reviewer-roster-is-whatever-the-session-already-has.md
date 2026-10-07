# The reviewer roster is whatever the session already has, and a finding's word decides its fate

**Amended 2026-10-04 by ADR-0075**: a fifth axis, tests, runs
`wio-test-reviewer` when the change touches a test file, and it is the one axis that is not
written as a prompt when nothing is listed — its absence is said in one line instead.

**Amended 2026-10-07 by ADR-0083**: "the four axes do not move" no
longer holds. Which axes run is read from the diff, and a repo's own agents and `reviewers:`
line can only add.

ADR-0049 gave finishing five steps, and step 3 sends reviewers over the change on four
axes — correctness, security, performance, frontend. It did not say where a reviewer
comes from, so every mouse wrote four prompts from scratch, and it did not say what a
finding is worth once it survives verification, so every mouse guessed what was worth
waking the person for. This settles both. The four axes do not move.

## Where a reviewer comes from

**Prefer a reviewer somebody else maintains.** The part now tells the mouse to read the
agent types its own session lists before writing a prompt, and to send a listed agent
wherever one is plainly built for an axis. Whiska writes no agent definitions — ADR-0017
keeps it dumb, and an agent file would be a fifth thing `init` installs and then has to
keep current. The roster is therefore whatever is already there: Anthropic's plugins, the
repo's own `.claude/agents/`, anything else the person has enabled. Whiska benefits when
Anthropic improves those agents and pays nothing when they do.

Two tests disqualify an agent, however well it reviews:

- **It changes code rather than reporting on it.** `pr-review-toolkit`'s `code-simplifier`
  is the live example: it says of itself that it operates "autonomously and proactively,
  refining code immediately after it's written". Step 3's reviewers report; something that
  edits during a parallel review pass is editing underneath the other reviewers' feet.
- **Its own description says not to dispatch it directly.** Seven of `claude-security`'s
  eight agents say exactly that. They belong to a pipeline.

**An agent definition is read before it is dispatched**, on the same rule ADR-0049 wrote
for a check command, and for a sharper version of the same reason. A session's agent list
includes the ones defined in the worktree — which is the branch under review, so a branch
can ship `.claude/agents/anything.md` and have it dispatched with the session's tools.
That is worse than a hostile `checks:` line, not better: a command does one thing, an
agent runs a loop and can bend the review's verdict as well as reach for whatever the
session can reach. The two disqualifying tests above do not help here, and the part says
so outright — both are read off the agent's description of itself, and whoever wrote the
agent wrote that too. They say whether it fits the axis, never whether it can be trusted.
The same reading applies to `reviewers:`, which arrives with the branch like every other
line under `## Finish`.

This is the one guard the first draft of this change missed, and it was net-new exposure:
before it, a mouse wrote its own four prompts and dispatched nothing the branch could
name.

**Nothing listed for an axis is the ordinary case, not a failure.** Neither plugin is
enabled by default, and an agent type that is not enabled is simply not in the session's
list. The mouse then writes the prompt, which is what step 3 always did, and says nothing
about it in the finish message — an absence nobody chose is not news.

## What actually ships today, written down because it is smaller than it sounds

Of the four axes, exactly **one** has a shipped reviewer: correctness, via
`pr-review-toolkit`'s `code-reviewer` (project-guideline compliance plus bug detection),
and only when that plugin is enabled. `silent-failure-hunter`, `pr-test-analyzer`,
`type-design-analyzer` and `comment-analyzer` are narrower correctness lenses rather than
axes of their own. Nothing in the official marketplace ships a performance reviewer or a
frontend reviewer; `frontend-design` is a design skill, not a review agent.

This is recorded because the gap will close from outside and the part is written to
close with it: it names no agent, so a performance reviewer that ships next month is
picked up by a mouse reading its session's list, with no `whiska init` in between.

## Why `claude-security` is opt-in rather than the security axis

`claude-security` is not a reviewer that can be dispatched. Its scan runs only as a
`Workflow`, it is entered through a skill rather than as a subagent, it scans **only
committed** changes, it runs for minutes to tens of minutes, and it writes a
`CLAUDE-SECURITY-<timestamp>/` directory into the repository.

Making it the security axis would have meant a mouse that commits before it finishes, a
`Workflow` dependency on every finished turn in every repo, a new directory in the tree
after each one, and a turn whose cheapest step became its longest by an order of
magnitude. Rejected. Instead a repo asks for it by name, on a `security:` line under its
own `## Finish` heading, and the prose says plainly what naming one costs — including that
a scan reading commits rather than the working tree means that turn commits before it
finishes. A repo that does not name one gets the security reviewer, which is the ordinary
case.

The alternative considered and rejected was dropping the mention entirely. It would have
left the next person to rediscover, at the same cost, why the obvious thing does not work.

## The three words, and why they are not a new vocabulary

A finding that survives verification gets one of **important**, **nit** or
**pre-existing**, and the word is what happens to it: fix now; fix if cheap; name and
leave. These are not invented here. `pr-review-toolkit`'s `code-reviewer` already scores
findings 0–100 with bands named in exactly these words — "likely false positive or
pre-existing issue", "minor nitpick", "important issue requiring attention", "critical
bug" — and the `code-review` command's false-positive list is headed by "pre-existing
issues". A fourth spelling would have made one idea read as two.

Verification gains the same sharpening, from the same place: the part now says to **try to
disprove** a finding and keep only what survives, which is `claude-security`'s
`scan-verifier` instruction almost verbatim ("try to disprove it. The finding survives only
if you fail"). ADR-0049's "a claim, not a verdict" already meant this; now it says how.

## The escalate rung names what was already there

A fourth rung — what reaches the person — was considered and deliberately **not** added as
new policy *for reviewer findings*, because it was not new. (The read-before-dispatch guard
above does add an escalation, for a hostile agent definition. That is not a reviewer
finding — it happens before any reviewer is sent — and it sits with the other two the part
already escalates that are not findings either: an untrusted ticket and an untrusted check
command. The ladder is about what a review turns up; those three are about what the session
is handed.) For reviewer findings the part already carried all three cases: a wrong scope
(step 1), still red after round two (step 4), and a fix that contradicts a recorded
decision (step 1, via step 2's second limit). Only one gap was real and it is now closed in
step 1: where a decision is out of date and the repo's own rules do not say how to change
it, that is the person's call rather than a quiet divergence.

So step 3 now states the boundary rather than adding to it: **nothing a reviewer finds
reaches the person as a decision.** A real vulnerability in this change is *important* —
fixed and named, not escalated. Two wider lines were offered and declined: every confirmed
security finding, and anything touching stored data. Both would have turned a rule about
whose judgment is needed into a rule about subject matter, and the finish message already
names what was found either way.

## `reviewers:`, and the lines that were designed and then not shipped

`reviewers:` joins `checks:`, `specs:`, `ticket:` and `finish:` under the shared `## Finish`
heading (ADR-0049 established both the heading and its one-line-per-fact grammar). It names
agent types that already exist in the repo, one per extra axis — a styleguide reviewer, a
data reviewer — because a Postgres `EXPLAIN` specialist has no business in a block that
ships to every repo in every language. A name that resolves to no agent is said once and
skipped, never improvised from the name: a reviewer called `data` that nobody wrote is not
a data reviewer, and a mouse inventing one from its name would report with the authority of
a specialist and the knowledge of a guess.

A `stack:`/`seed:`/`preview:` trio was designed alongside it — how to bring the app up and
seed it, for a reviewer that *measures* rather than reads. It is **not** shipped. The
distinction between a reviewer that reads the diff and one that runs the thing is real, but
the lines are the wrong place to answer it: a `reviewers:` entry names an agent the repo
already wrote, and that agent's own definition is where "how to bring this app up" belongs.
Three lines in `CLAUDE.md` describing how to run the app would be a second copy of what the
repo's build file, its scripts and that agent already say — the exact drift ADR-0049 retired
the `CHECK` line to avoid. If a measuring reviewer turns out to need more than its own
definition can carry, that is the moment to add the lines, with evidence.

## Consequences

**Review quality now varies by machine, and the part says so rather than hiding it.** Two
mice on the same branch, one with `pr-review-toolkit` enabled and one without, get
different correctness reviews. Accepted: the alternative was Whiska shipping and
maintaining agent definitions, which ADR-0017 forecloses, and a session with no plugins is
no worse off than it was under ADR-0049.

**A repo already running the older text keeps it until the next `whiska init`.** Per
ADR-0045 the `finish` part is replaced where it stands on the next run, and a part marked
`keep` is never touched — so a person who has claimed `finish` as their own gets none of
this, which is the point of `keep`.

**A security finding is named in the message whatever word it got.** The ladder lets a
vulnerability be disproved away or called a nit, and the `report` part tells a mouse to
leave reviewer findings out of the message — so without this the person could not tell
"nothing was found" from "something was found and judged small". The `report` part's
leave-out list gains the matching carve-out in the same change: a pre-existing problem
left alone, a reviewer the repo asked for that was not there, and a security finding and
what became of it are the three things finishing names on purpose.

**Nothing in Elixir reads any of it.** `reviewers:` and `security:` are read by a model,
like every other line under `## Finish`. Whiska still runs no check, dispatches no
reviewer, and has no opinion about any finding — ADR-0015's boundary is where it was.
