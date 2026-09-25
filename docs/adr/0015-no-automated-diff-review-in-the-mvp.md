# No automated diff review in the MVP — the human is the review

Automated review (a model reading the change and judging it, not just running commands) is
a meaningfully bigger piece of work than anything else in this design, and firstmate does
not automate it either — its Captain sees hold *state*, not a diff, and reads code
manually. Whiska matches that shape rather than inventing something bigger: the human is
the review, exactly as with any PR, and what Whiska does is remove the friction of getting
to the diff.

Every push-approval question carries `whiska diff <id>` as its next step. That command
respects `git config diff.tool` — if one is configured it opens there via `git difftool`,
otherwise it prints a plain `git diff`. There is deliberately no separate Whiska setting:
git already has a well-established pluggable answer to "which diff tool", so Whiska defers
to whatever you have already told git.

## Consequences

What protects you without an automated reviewer, concretely: every push is a real decision
with a diff-stat scope check and a one-command path to the full diff; `PreToolUse`
physically confines edits to the worktree; `checks.yml` catches anything mechanical first;
`whiska cleanup` verifies a branch is merged before removing it; and CI is a second layer
outside the mouse's environment if PR mode is ever turned on.
