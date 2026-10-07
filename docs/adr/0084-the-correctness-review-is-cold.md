# The correctness review is cold, and every reviewer's findings reach the person whole

Amends ADR-0083 (its "Correctness always runs" and its combined small-diff reviewer),
ADR-0049 and ADR-0054 (a finding that does not survive is no longer dropped: it stays,
marked disputed).

## What was decided

**The reviewer that always runs is the `cold-review` skill**, shipped by `whiska init`. It
forks into its own read-only Explore subagent (`context: fork`, `agent: Explore`,
`background: false`), writes its own brief, and takes only two optional arguments, a base
and a spec. It finds the change itself (base to working tree, untracked files included),
reads the decisions as they stood at the base with `git show <base>:<path>`, and treats
anything the builder wrote as a claim. It reads no decision from the branch (ADR-0072,
rule 3); its own `SKILL.md` is still a file a branch could edit in a repo that commits its
skills, which this decision does not close. "Read-only" is the Explore agent's tool set
(no Edit or Write) plus the prompt's rule that every command reads; Bash is not
restricted further. On a small diff it is the one reviewer, beside tests and frontend. It
replaces the written correctness reviewer.

**No substitute.** Where the skill is not installed, finishing sends no other reviewer and
the report says in one line that the cold review did not run.

**It runs in the foreground.** ADR-0052's stop hook counts only subagents launched through
the `Agent` tool (`lib/whiska/transcript.ex`); a background skill would be invisible to it
and a pause would be delivered as a report. Finishing sends the trigger reviewers to the
background first, then invokes the skill, so they still run in parallel.

**It is not a `claude -p` session.** Started from a mouse's worktree it carries the mouse's
pane id, so Whiska would take it for the mouse (ADR-0053).

**Every finding reaches the person.** Finishing still tries to disprove each finding, but
deletes none. The cold review goes into the report whole; every other reviewer's findings
go in as numbered items in the reviewer's own words. Under each, one line: its word
(important, nit, pre-existing) and what became of it, or **disputed** with the code that
disproves it.

## Alternatives not taken

- **A fixed agent file.** The caller writes the task prompt, so the caller shapes the brief,
  and a branch's own `.claude/agents/` copy overrides the user's.
- **A `claude -p` session.** A whole new session per review, and ADR-0053's collision.
- **The no-mistakes review step.** About $55 to $60 and 13 minutes per run.
- **A fallback correctness reviewer.** The person ruled it out: a missing cold review is
  stated, not quietly replaced by a briefed one.
- **Keep both reviewers.** The same thing reviewed twice, once briefed and once cold.

## Consequence

A finished mouse costs an estimated $0.5 to $1.5 more, and a small diff about $1 to $2
instead of $0.62; the first agent ledgers give the real figures. A mouse can no longer hide
a finding by disproving it wrongly: the person reads the disproof beside it.
