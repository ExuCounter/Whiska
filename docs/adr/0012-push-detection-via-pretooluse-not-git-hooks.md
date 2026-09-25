# Push detection goes through PreToolUse; a git pre-push hook is only a weak second layer

Researched, and a real git `pre-push` hook loses on both counts. It is skipped outright
by `git push --no-verify`, so it is convenience rather than enforcement; and there are
real, currently open bugs in Claude Code itself around worktrees silently breaking or
redirecting `core.hooksPath` (anthropics/claude-code #66993, #88747) — a landmine given
Whiska is worktree-heavy.

A `pre-push` hook is still worth keeping as a cheap extra net on top, because it catches
anything that reaches `git push` without going through Claude Code's tool-call path at
all, which `PreToolUse` by definition cannot see. Belt and suspenders, not a replacement.

## Consequences

Detecting a push inside an arbitrary bash string is imperfect, so Whiska errs broad: it
matches anything push-shaped and asks. A false "are you sure?" costs nothing; a missed
real push does.
