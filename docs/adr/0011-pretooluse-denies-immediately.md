# PreToolUse always denies immediately; approval runs asynchronously

A hook has to answer fast. It cannot stay open while a test suite runs, and it certainly
cannot stay open while a human decides. So `PreToolUse` never blocks-and-waits: the
instant a mouse tries to push, the hook denies that exact attempt on the spot with "hold
on, checking" as the tool's result. The mouse's original attempt is dead, not paused.

Everything after that — checks, then approval, then the real push — runs asynchronously,
off to the side, through the same delivery machinery questions already use.

## Consequences

When you eventually answer yes, **Whiska runs `git push` itself**, directly, in that
worktree. It has to: the original tool call is long gone, and this must not depend on the
mouse's pane being free or idle at whatever moment you get around to answering, which
could be minutes or hours later. Running the push is purely mechanical and needs no
reasoning, so it does not violate "Whiska stays dumb".

Check failures come back the same way — as a message delivered into the mouse's own pane,
the same shape as any other failing command it already knows how to react to mid-task.
Bounded escalation: two failures in a row on the same push attempt turn the next one into
a real question to you, carrying the failure output. The counter resets on a successful
push or once you resolve the escalated question.
