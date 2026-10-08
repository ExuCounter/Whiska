# Dead mice and stuck mice are separate problems needing separate mechanisms

**Dead** means the pane itself is gone, closed or crashed. That is a clean yes/no, and
herdr reports it without being asked: its socket API emits `pane_closed` and
`pane_exited`, so the owl subscribes rather than polling. herdr 0.8.2 emits neither for
the panes of a workspace it closes; dropping a worktree sends `workspace_closed` alone,
so the owl subscribes to that too, and since it names no pane the house re-lists herdr's
panes and marks dead every mouse it no longer finds. The owl still reconciles against
herdr at startup, which covers anything that died while it was down, and the backstop
catches a dropped subscription. Reconciliation walks mice, not questions, since several
questions can share one dead pane.

**Stuck** means the pane is alive and Claude Code is running, but nothing is progressing.
That is invisible to the same check, because the pane genuinely does exist. One kind of
stuck is diagnosed exactly and handled: a turn that ended without reaching the doorstep,
the dead turn ADR-0067 picks up. The rest, a mouse genuinely looping or gone quiet
mid-turn, is read from a proxy, the last action from its own transcript (ADR-0050) not
changing for a long while with no open question waiting on the person, and is reported,
not acted on.

## Consequences

Stuck handling is a ladder, cheap fixes before bothering the person: check its own
unanswered questions first in case delivery was merely delayed; re-state existing
instructions, never a new decision; one corrective line, one shot; relaunch against the
same worktree; escalate to the person only after a second relaunch still fails. The
pickup is rung three, built for the dead turn, and satisfies the first two rungs by
construction: a mouse with anything open or sent is never picked up, and the line
re-states and decides nothing. Rungs four and five are unbuilt.

Rung two is bounded deliberately. If the confusion is about something the person already
decided in the same conversation, relaying it again is not a new call; otherwise that rung
is skipped. The main session never infers or decides something new on their behalf.

Getting the pane back is easy, since the worktree folder is still on disk. Getting the
exact conversation back is not confirmed: whether Claude Code's session resume works
through herdr is unverified and deliberately not promised.
