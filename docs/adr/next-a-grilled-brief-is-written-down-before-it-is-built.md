# A grilled brief is written down, and approved, before it is built

Under ADR-0063 a mouse grilled and then built straight from the answers. Nothing wrote down
what those answers added up to, and the person's ok was on choices one at a time, never on
the whole. The person already had a skill for writing it down, `to-spec`, in their
dotfiles. A session could not run it, since it carried `disable-model-invocation`, and it
published to an issue tracker that this setup does not have.

## The rule

After the last grilling round the session runs `whiska-spec`, unless the task is a tweak
or quick fix. The skill writes the spec to `.whiska-spec.md` at the worktree root and sends
the whole spec to the person as a question. The session builds only when they reply "ok".
Any other reply revises the file, and the whole spec goes out again.

A brief that needed no grilling gets no spec, because the person's own words already are
one. A spec is written only after grilling, never in place of it.

The finish pipeline's first step reads the work back against the spec, beside the brief.

## Whiska owns both skills

`to-spec` and `grilling` move out of the person's dotfiles into `priv/skills/`. Both
scopes install them, exactly as ADR-0046 and ADR-0055 ship the others. The person drops
the dotfiles copies, so each skill has one copy.

The spec skill keeps the person's template in full, the long user-story list included.
Three things change:

- The issue-tracker step and its triage label are gone.
- The separate check on test seams is gone, because the ok on the spec covers them.
- A session may run it.

It is named `whiska-spec`, not `to-spec`. Its behaviour differs. Also,
`~/.claude/skills/to-spec` is a symlink into the dotfiles repo, and the global install
writes through a symlink (ADR-0056), so keeping the old name would rewrite the person's
copy in place.

`grilling` is copied word for word under its own name. The block does not point at it.
The skill walks every branch of the design tree, while ADR-0063 asks only the costly
choices and decides the cheap ones, so pointing a mouse at the skill would undo ADR-0063.
It ships so the person keeps one copy of it.

## The spec is a file git ignores

The alternatives:

- **A file committed on the branch.** It is durable and reviewed in the diff, but
  teammates see these files in every repo Whiska is installed in.
- **The repo's issue tracker**, as `to-spec` had it. It needs setup per repo, and it
  publishes outside the machine.
- **Only the question.** Nothing is left for the finish pipeline to read back.

The person chose a file that is never committed. Untracked is not enough on its own. The
owl takes a landed worktree down only when `git status --porcelain` reads clean
(ADR-0061), and an untracked file is listed there. So `whiska shape` adds `/.whiska-spec.md`
to the main checkout's `.git/info/exclude`. That file is local, never committed, and read
by every worktree of the repo. The pattern is anchored at the root, so a file of that name
deeper in the tree stays visible.

The skill checks `git check-ignore` itself and adds the line if it is missing. That covers
a mouse that was never shaped, and a session working in place. `git worktree remove`
without `--force` deletes ignored files, so the spec goes with the worktree. Once the
branch lands, the commits hold the outcome.

## The person sees it before the build

The alternative was to write the spec and build at once. That costs no round trip, and
the grilling answers have already settled the choices. The person chose to see the whole
spec before any code, at the cost of one more round trip on every grilled task.

The whole spec goes in the question, because `whiska questions <id>` is where the person
reads it, cold, from another terminal. The report part's size cap names it as an
exception.

## Consequences

ADR-0063 is amended. On a grilled task a mouse now waits for two oks: one on its costly
choices, then one on its spec.

The block grows from 152 lines and 1550 words to 158 and 1619. That is exactly what the
rule costs.

Both scopes now ship nine skills.

`.whiska-mouse` has the same problem in any repo whose `.gitignore` does not list it: it is
untracked, so the owl will not take that worktree down. The same exclude line would cover
it. That is left for a change of its own.
