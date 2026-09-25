# Dead mice and stuck mice are separate problems needing separate mechanisms

**Dead** means the pane itself is gone — closed or crashed. That is a clean yes/no, so a
periodic sweep every few minutes can catch it by asking herdr whether each `Mouse` row's
pane still exists. The sweep walks mice, not questions, since several questions can share
one dead pane and there is no reason to ask herdr the same thing twice. The same sweep runs
once immediately on startup, which covers restart recovery for free.

**Stuck** means the pane is alive and Claude Code is running, but nothing is progressing.
That is invisible to the same check, because the pane genuinely does exist. Detection
reuses a signal that already exists — the last-tool-call excerpt from "knowing what a mouse
is doing". If it has not changed in a long while *and* there is no open question waiting on
you (so it is not simply waiting for an answer), that is worth a look.

## Consequences

Stuck handling is a ladder, cheap fixes before bothering you, the same philosophy as the
bounded retry on failed checks: check its own unanswered questions first in case delivery
was merely delayed; re-state existing instructions, never a new decision; one corrective
nudge, one shot; relaunch against the same worktree; escalate to you only after a second
relaunch still fails.

Rung two is bounded deliberately. If the confusion is about something you already decided
earlier in the same conversation, relaying it again is not a new call. If it is not, that
rung is skipped — the main session never infers, extrapolates, or decides something new on
your behalf.

Getting the pane back is easy, since the worktree folder is still on disk. Getting the exact
*conversation* back is not confirmed: whether Claude Code's session-resume works through
herdr is unverified, and is deliberately not promised. `whiska reopen` degrades gracefully
either way.
