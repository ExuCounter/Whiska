# Hard rules are a PreToolUse hook that denies at once

A rule that must hold whatever the model decides is enforced by the `PreToolUse` hook,
which runs before a tool call and can block it. A line in a session's rules is a
suggestion, followed only if the mouse chooses to. The split is deliberate: the rules
carry everything that takes judgment (ADR-0081), and the hook carries the short list that
must hold regardless — containment in the worktree (ADR-0013), sniff mode, the read-only
allowlist for shell commands (ADR-0034), the person's own commands and a hold
(ADR-0079). The same principle is applied wherever it matters: cleanup checks that a
branch is merged rather than trusting a skill to remember (ADR-0061).

The hook never waits. It answers in milliseconds — it cannot stay open while a test suite
runs, and certainly not while a human decides — so it denies the attempt on the spot, with
the reason as the tool's result, and anything slow runs asynchronously through the same
delivery machinery questions use. The mouse's original attempt is dead, not paused.

## A push is caught by the hook, matched broadly

Push detection goes through the hook, not a git `pre-push` hook. A `pre-push` hook is
skipped outright by `git push --no-verify`, and Claude Code has open bugs around
worktrees silently breaking or redirecting `core.hooksPath` (anthropics/claude-code
#66993, #88747), a landmine for a tool that is all worktrees. It is still worth keeping
as a cheap second net, since it catches a push that never went through a tool call, which
the hook by definition cannot see. Detecting a push inside an arbitrary bash string is
imperfect, so Whiska errs broad: anything push-shaped is matched. A false "are you sure"
costs nothing; a missed push does.

## Designed, not built: push approval

Approval is designed as a question carrying the diff and nothing else, through the
ordinary delivery path. On a yes, Whiska runs `git push` itself in that worktree, because
the original tool call is long gone and the push must not depend on the mouse's pane being
idle whenever the person gets round to answering; running it is mechanical and needs no
reasoning. A push that fails for a real reason comes back into the mouse's own pane like
any failing command, with bounded escalation: two failures in a row on the same push turn
the next into a real question carrying the output. None of this is built; the hook today
denies a push and the mouse says so in its report.

## Considered options

- **A hook that blocks and waits** for checks or for the person. It would hang the pane
  for as long as a suite or a human takes.
- **Git hooks as the enforcement.** Convenience, not enforcement: one flag skips them.
- **Judgment in the hook** — reading the diff, deciding what counts. The hook has fixed
  rules; judgment belongs to the model reading the rules.

Folded in on 2026-10-08: 0010, 0012 (their text is in git history).
