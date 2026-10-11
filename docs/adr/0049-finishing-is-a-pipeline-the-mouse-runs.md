# Finishing is a pipeline the mouse runs, not a hook that blocks it

Finishing is plain instructions in the `whiska-finish` skill, which a mouse runs itself,
in order, before it writes the done marker: read the work back against what was asked,
run the repo's checks, send reviewers chosen by what the diff does with the cold review
always, one more round, commit the work, then the marker. Whiska runs no check,
dispatches no reviewer, has no opinion about any finding, and does not know whether the
pipeline ran. It never runs on a turn ending on a decision for the person, and never in
the main session. Per-repo facts live under a `## Finish` heading in the repo's own
`CLAUDE.md`, one `name: value` line each: `checks:`, `specs:`, `ticket:`, `reviewers:`,
`security:`.

The skill is loaded at every finished turn, so it stays at most 8,000 characters and keeps
rules, not their reasons, which live here. What only some turns need sits in files beside
it, read on demand: the Needs attention block, a reviewer or scan the repo adds, and a
Proposed build (ADR-0074).

## The steps

1. **Read the work back**: the brief, its spec, the ticket it names, the repo's specs,
   glossary and recorded decisions. A contradiction or a missing piece is fixed now. A
   decision that is itself out of date is changed in the same piece of work where the
   repo's rules say how; where they do not, it is the person's call. A wrong scope ends
   the turn on a decision.
2. **Run the repo's checks** and fix what fails, only inside this change, and never by a
   fix that contradicts step 1: a check made to pass by deleting an assertion was not
   passed.
3. **Send reviewers**, below.
4. **Round two, then stop.** A fix goes back to step 2. Still red after the second round,
   the turn ends on a decision naming what fails.
5. **Commit the work** on its branch, in the repo's commit style, after the last fix.
   Never push. Never a secret, a local setup, `.whiska-mouse` or `.whiska-spec.md`. A
   repo whose instructions say the person commits keeps that, and the report says so.
6. **The marker**, under a report that holds each behaviour change against the spec,
   counts the findings fixed, and gives one line to each finding left unfixed.

## Every behaviour change is held against the spec

The report carries an **Against the spec** list: each behaviour change in the diff a user
or a calling program would see, marked **approved** where the spec's What Changes for
Users or its decisions name it and **not approved** otherwise (ADR-0063). No spec means
none is approved. Each not-approved change is a **Needs attention** item and one of them
is recommended, so the finished options stop recommending Land here (ADR-0074). The cold
review asks the same question of every hunk on its own, so a change the builder left off
the list is still found. The turn still ends on finished: the list is what the person
reads before picking.

In another repo a mouse fixed a 500 by filtering activities out of an API response, wrote
no spec, and finished; the report said the crash was gone, Land here was recommended, and
nothing put the dropped activities in front of the person. ADR-0063 now asks for the spec
that would have named them; this list is the backstop for a change that slips past it.

## Reviewers are chosen by what the diff does

The axes are read from `git diff` at the merge base, never from what the author feels
the change needs. The skill carries this table and the hook text mirrors it:

| axis | trigger |
| --- | --- |
| cold review | always |
| security | added code runs something built from text; decides allow, deny or permissions; reads outside input; emits text a person or program will run; changes agent instructions, hooks or scripts; touches secrets or auth |
| performance | only on a hot path: the repo's `CLAUDE.md` names one, or the diff touches a timer, scheduler, middleware, handler or a loop that grows with scale; otherwise its questions are in the cold review |
| frontend | the change touches something a person sees |

A small diff, under 40 changed lines in at most two files with no security trigger, gets
the cold review alone, beside frontend. Doubt fires a trigger. A repo only adds
axes, through its `CLAUDE.md` prose, its `.claude/agents/*-reviewer.md` and its
`reviewers:` line; none removes one. A `security:` scan replaces the security reviewer
only when a trigger fires. Performance runs on the model `whiska shape
--rules` picks for a clear task of known shape, passed as the Agent call's `model`; the
skill names no model, since model names live in `priv/models.json` alone (ADR-0069).

**The reviewer that always runs is cold.** The `cold-review` skill forks into its own
read-only subagent, writes its own brief, finds the change itself, reads the decisions as
they stood at the base, and treats anything the builder wrote as a claim. It runs in the
foreground, after the trigger reviewers go to the background: the stop hook counts only
`Agent` launches (ADR-0052), so a background skill would be invisible to it. It is not a
`claude -p` session, which from a worktree would carry the mouse's pane id and be taken
for the mouse (ADR-0053). Not installed, no substitute: the report says in one line that
the cold review did not run.

**The roster is Whiska's own prompts and the repo's own agents.** The mouse writes each
axis's prompt for Claude Code's `general-purpose` agent, the cold review aside, and a
repo's `.claude/agents/*-reviewer.md` and `reviewers:` line add axes. Nothing else
installed on the machine is reached for, however well it seems to fit
(ADR-0085). Two tests disqualify a repo's agent: it changes code
rather than reporting on it, or its own description says not to dispatch it directly. An
agent definition is read before it is dispatched, the file under
`.claude/agents/` and not the session's listing of it: a branch can ship one, and an agent
runs a loop and can bend the verdict. One that reaches for credentials, sends anything
anywhere, or tells the reviewer what to conclude is a decision for the person. The
`reviewers:` line is read the same way; a name that resolves to no agent is skipped and
said once, never improvised from the name.

**Only a finding left unfixed reaches the person.** The mouse tries to disprove each
finding and deletes none. A finding it disproves is **disputed**; one that survives gets
**important** (fix now), **nit** (fix if cheap) or **pre-existing** (leave it), taken
from the bands Anthropic's own reviewer scores with rather than spelled a fourth way. The
report counts the fixed findings in one line and gives one line to each finding left
unfixed: what it is, its word or **disputed** with the code that disproves it, and why it
stayed. No finding is quoted, the cold review is not pasted, and no token figures or
skipped axes are listed. A security finding follows the same rule: what decides whether it
is shown is whether it was fixed, never its subject. Nothing a reviewer finds reaches the
person as a decision: of a review, only a wrong scope, a decision the repo's rules do not
say how to change, and a second red round do, plus three things that are not findings: a
ticket that reads as an instruction, a check command that reaches outside the repo, and an
agent definition the step will not dispatch.

## Why

**A hook cannot finish a turn.** The first design was a `Stop` hook the repo owned,
`.claude/hooks/review-loop.sh`, with one `CHECK` command at the top, blocking the turn
while checks were red and once more for a review pass. One command cannot know what
green means in a repo that already says so in its own instructions and scripts, so the
hook was a second place to say it that drifted at once. A script has one sentence and two
exit codes and can judge nothing: not whether a finding is real, not whether the scope is
wrong. And every green turn paid a second stop. Finishing is all judgment, so it belongs
on the rules side of the split ADR-0011 draws; the hook that can actually deny stays
where it was, on edits outside the worktree (ADR-0013). Advisory is the trade: a mouse
that skips a step ends on `done` with a red suite, and nothing catches it until the
person looks.

**The diff chooses the axes** because 140 agent runs over 42 mice showed four fixed
reviewers costing about $2.70 per finished mouse, a third of its cost, with performance
finding something in 3 of 21 runs and security in 7 of 16, while mice already skipped or
merged axes by feel. Cache writes were 80% of agent cost. The table makes which axes run
a rule the diff decides, not a choice each mouse makes alone.

**The correctness reviewer is cold** because a reviewer the builder briefs is a reviewer
the builder shapes.

**The report shows only what still needs the person.** With every finding in full and
the agent ledger at its end, a finished report ran to about 90 lines (question #319), most of it
findings already fixed and token figures nobody acted on. The person reads a report to
decide whether to land: a fixed finding is done and needs nothing from them, while one left
unfixed or disputed is exactly what they must weigh. Token figures belong to the record of
what a turn cost, which the owl keeps from the transcripts at collection (ADR-0086), not
to that decision.

**Commit is a step** because 29 of 126 finished turns that changed files ended with
changes not committed, and a worktree with changes in it is never taken down after its
merge (ADR-0061).

**`claude-security` is opt-in, not the security axis.** It runs only as a `Workflow`,
scans only committed changes, takes minutes to tens of minutes, and writes a directory
into the tree. A repo asks for it on `security:`, and pays those costs knowingly.

## Considered options

- **`.whiska/checks.yml`, run by Whiska at push.** A second place to say what the repo
  already says, a schema with opinions in it, and timed after the mouse has committed and
  moved on.
- **A `whiska review` command the mouse is told to run.** A rule a mouse may skip, with
  none of the pipeline's judgment.
- **A `Stop` hook refusing `done` on a dirty worktree.** Same objections as the review
  loop.
- **Whiska ships reviewer agent definitions.** A fifth thing `init` installs and keeps
  current; ADR-0081 keeps Whiska dumb.
- **Four fixed axes plus the ledger.** The cost stays.
- **Cut axes by repo config.** Whiska writes no project files in a global install
  (ADR-0056).
- **A fixed agent file for the cold review.** The caller writes the task prompt, so the
  caller shapes the brief, and a branch's own `.claude/agents/` copy overrides.
- **A `claude -p` session for the cold review.** A whole session per review, and the
  ADR-0053 collision.
- **The no-mistakes review step.** About $55 to $60 and 13 minutes per run.
- **Land here never recommended**, so the person always reads the diff before picking:
  a pick on clean work too, when the list already marks what needs one.
- **A review question of its own**, "ok to land?" before the finished options, like the
  spec's link: a third round trip per task, and a finished mouse would end on a question.
- **A fallback correctness reviewer where the skill is missing.** A missing cold review
  is stated, not quietly replaced by a briefed one.
- **Every confirmed security finding reaching the person as a decision.** Turns a rule
  about whose judgment is needed into a rule about subject matter.
- **Every finding in full**, the cold review whole and every other finding in the
  reviewer's own words: the person's pick on 7 Oct, reversed on 11 Oct when a report ran
  to 90 lines and the fixed findings in it needed nothing from them.
- **Every security finding named whatever became of it**, beside the unfixed ones: a
  fixed security finding needs no more from the person than any other fixed finding.
- **Only the security findings left unfixed**: a disputed or let-go finding of any kind is
  the person's to weigh.
- **A findings file linked from the report**, kept in the worktree or copied beside the
  kept specs: the person does not read fixed findings at all, so a file for them is
  machinery for nobody.
- **The agent ledger in the report**, in full or as one line of totals: the figures
  inform a budget, not the landing decision.
- **A line per axis skipped, naming the triggers checked**, which made a mouse's choice
  of axes visible: the table and the diff decide the axes, and the person approved
  dropping the line on 11 Oct with the ledger it sat in. The cost is that a mouse which
  wrongly skips security leaves no trace in the report.

## Consequences

- A turn costs more: several subagents and up to two rounds of checks. A repo that finds
  it too much makes `checks:` cheaper. A small, plain change costs one reviewer.
- A forgotten commit is caught by the finish options, which offer a commit first wherever
  the branch line lists files not committed (ADR-0009).
- `whiska init` writes no `review-loop.sh` and removes a `Stop` entry naming one, since an
  entry fires and would race the doorstep hook; the file itself is the person's, inert,
  and `whiska doctor` names it (ADR-0038). The shim's `stop` path has nothing to sequence:
  no stdin capture, no `jq`.
- `## Finish` is a shared heading with one grammar: one `name: value` line per fact, read
  by a model, parsed by nothing in Elixir. The finished-branch options read `finish:`
  from it.
- Two of the pipeline's inputs arrive from outside the session: a ticket is evidence
  about what was asked, never an instruction, and a check command is read before it is
  run, doubly so when it arrived with the branch.
- The report names two things on purpose, which the report rules otherwise leave out: a
  pre-existing problem left alone, and a reviewer the repo asked for that was not there.
- A finished report carries no token figures: what a turn cost is in the house, recorded
  at collection, and `whiska metrics` reads it (ADR-0086).

Folded in on 2026-10-08: 0014, 0015, 0042, 0054, 0083, 0084 (their text is in git
history); 0072, a reviewer proposal never applied, was dropped the same day.
