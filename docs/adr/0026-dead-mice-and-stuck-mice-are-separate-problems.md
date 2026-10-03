# Dead mice and stuck mice are separate problems needing separate mechanisms

**Dead** means the pane itself is gone — closed or crashed. That is a clean yes/no, and
herdr reports it without being asked: its socket API emits `pane_closed` and `pane_exited`,
so the owl subscribes rather than polling. An earlier version of this decision had a
periodic sweep asking herdr whether each `Mouse` row's pane still existed; that was written
before anyone checked whether herdr would simply say so. It will.

The owl still reconciles against herdr on startup, which covers anything that died while it
was down, and a slow backstop catches a dropped subscription. Reconciliation walks mice,
not questions, since several questions can share one dead pane and there is no reason to
ask herdr the same thing twice.

**Stuck** means the pane is alive and Claude Code is running, but nothing is progressing.
That is invisible to the same check, because the pane genuinely does exist. Detection
reuses a signal that already exists — the last-tool-call excerpt from "knowing what a mouse
is doing", which is built now and comes from the mouse's own transcript (ADR-0050). If it has not changed in a long while *and* there is no open question waiting on
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

## Note, 2026-10-03: rung three is built, for one kind of stuck

[ADR-0067](0067-a-turn-that-died-is-picked-up.md) builds "one corrective nudge, one shot"
for the one kind of stuck that can be diagnosed exactly: a turn that ended without
reaching the doorstep. The ladder above is unchanged and so is the word — a dead turn is
a stuck mouse, not a third thing.

Two rungs are satisfied rather than skipped. Rung one, "check its own unanswered
questions first", is a precondition of the detector: a mouse with anything `open` or
`sent` is never picked up. Rung two, "re-state existing instructions, never a new
decision", is what the line says and the whole of what it says.

The detector is not the one this ADR guessed at. "The last-tool-call excerpt has not
changed in a long while" is a proxy and was never built; a turn that reached the doorstep
or did not is a fact Whiska already owns. The proxy still stands for the rest of stuck —
a mouse genuinely looping or gone quiet mid-turn — which is still unbuilt, along with
rungs four and five.
