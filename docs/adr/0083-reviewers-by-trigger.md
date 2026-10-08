# Reviewers are chosen by what the diff does, and every finished report ends with an agent ledger

Amends ADR-0049 and ADR-0054 (the axes are no longer a fixed four), ADR-0072 (applies its
"the finish message names which reviewers ran" carve-out, and replaces its required set with
a trigger table) and ADR-0075 (the scout is gated, and runs on a cheaper model).

## The evidence

140 agent runs over 42 mice since 2026-10-04:

- Every finished mouse paid about $2.70 for reviewers, a third of its cost.
- Performance found something in 3 of 21 runs. Security found something in 7 of 16.
- Cache writes were 80% of agent cost.
- Real per-agent token counts already arrive at hand-back (`subagent_tokens`, `tool_uses`,
  `duration_ms`) and reached no report.
- Mice already skipped or merged axes, unwritten, so the person could not see which.

## What was decided

**Correctness always runs. The other axes run when the diff says so**, from a table in
`whiska-finish` step 3: security when any of its triggers fires, performance only on a hot
path (otherwise its three questions join the correctness prompt), frontend and tests as
before. A diff under 40 changed lines, in at most two files and with no security trigger,
gets one combined reviewer. Performance and the scout run on the model `whiska shape
--rules` picks for a clear task of known shape, through the Agent call's `model` parameter;
the rest inherit. The model is not named in the skill, because ADR-0073 keeps model names in
`priv/models.json` alone.

**The author still does not decide alone.** ADR-0072's line holds in a new form: the
triggers are read from the diff, not from the author's feeling; a repo's `CLAUDE.md`
prose, its `.claude/agents/*-reviewer.md` and its `reviewers:` line can only add; and every
skipped axis is named in the report with the triggers checked, so a missing review is a gap
the person can see.

**Every finished report ends with an agent ledger**: one line per agent sent (axis, agent
type, model that ran, new tokens, cache reads, steps with the average per step, tool uses,
seconds, findings and what became of them), a line for the mouse's own session, and one
line per axis skipped. New tokens are cache writes plus input plus output; cache reads are
their own figure, kept out of new tokens.

*Amended 2026-10-08.* The figures come from `whiska ledger`, which reads Claude Code's
transcripts on disk, not from the hand-back usage block. Read from real sessions, the
hand-back's `subagent_tokens` is the size of the agent's last call, not a sum; the cold
review (ADR-0084) hands back no usage at all; and the mouse's own session has no hand-back,
though its cache reads were its largest cost (8.4M in one session, against 164k cache
writes). Cache reads are therefore shown, apart from new tokens, so a later budget can
price a line. Steps and the average conversation per step say whether big cache reads came
from many steps or from one large context. A subagent's mid-run output counts are written
while its reply streams and are cut short, so such a line is marked "≥" as a lower bound.
`whiska ledger --json` prints the same figures as data, which is what a per-branch budget
would sum.

**The scout is gated** (ADR-0075): it runs only when a touched module has no test file, the
brief names no observable behaviour, or three or more modules change. Otherwise the mouse
names the test and says in one line the scout was skipped.

## Alternatives not taken

- **Keep four fixed axes and only add the ledger.** Cheap, but the cost stays.
- **Cut axes by repo config.** Whiska writes no project files in a global install
  (ADR-0056).
- **Name `sonnet` in the skill.** Breaks ADR-0073's one-file model edit.

## Consequence

A small, plain change costs one reviewer instead of three or four. A change that runs
something built from text, or decides access, still gets a security review.
