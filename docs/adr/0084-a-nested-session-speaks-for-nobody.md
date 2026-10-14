# A Claude Code session running under another one speaks for nobody

ADR-0053 identifies a session by where it started and which pane it runs in. Both signals
fail for a `claude` the mouse starts itself. Seen on 2026-10-10: a dotfiles mouse ran a
test script that started a real `claude --model haiku` in a pty inside its own worktree.
That child read the global hooks, started in the mouse's worktree, and inherited the
mouse's `HERDR_PANE_ID`. Each turn it ended was filed as a message from the mouse, and the
person got "feat/cmd-click-links stopped without saying why" twice, carrying the test's
output. The same child could have taken an answer the person saved for the mouse
(ADR-0080), which the mouse would then never see.

## Decision

A session whose `claude` process has another `claude` among its ancestors is **nested**,
and speaks for nobody. Claude Code puts `CLAUDE_PID` — the `claude` process that fired the
hook — in every hook's environment. The walk starts at that process's parent, so a
session never counts against itself, and reads the process table once with `ps`. It stops
at a process named `herdr`: a pane is where a session begins, so a herdr started from
some `claude`'s shell does not make every mouse inside it nested.

- `Stop` leaves nothing on the doorstep.
- `UserPromptSubmit` hands over no answer and stamps nothing taken. In the main checkout,
  a `claude` the main session started settles no finished line: it is not the person.
- `PreToolUse` is unchanged: a nested session in a mouse's worktree is stopped by that
  mouse's hold (ADR-0079). It does not carry the mouse's deny list, which is a launch flag
  (ADR-next-a-mouse-starts-in-bypass-mode).

When the walk cannot be made — no `CLAUDE_PID`, `ps` failing or taking over a second, a
process gone mid-walk —
the session is not nested, and its message is delivered as before. An extra message is
noise; a lost one is a mouse nobody hears (ADR-0009).

The hook shim forwards `CLAUDE_PID` to the owl, and the owl reads it from the hook's
environment, never its own (ADR-0033). A shim installed before this sends none, so nested
sessions get through there as they did before. `whiska doctor` already fails a shim that
differs from what `init` writes; for one that does not forward `CLAUDE_PID` it now says
what that lets through.

## Consequences

Nothing is stored, so nothing has to be kept in step: a mouse that restarts, resumes,
`/clear`s or compacts is still the mouse, because it still runs under no other `claude`.

It costs one `ps -A` per finished `Stop`, and per `UserPromptSubmit` that has an answer or
a finished line waiting: about 28 ms on a machine
with 800 processes, measured 2026-10-10. It grows with the machine's process count, not
with the number of mice. `PreToolUse` does not pay it.

A `claude` is recognised by its process name, which any process can take. A wrapper
script named `claude` between herdr and a mouse would silence that mouse. Under
ADR-0024's one-user limit this gains an attacker nothing, so the risk is an accident, and
the doctor does not look for it.

A Claude Code installed through npm shows
up as `node`, so a nested session under it is not caught, and its turns still reach the
person as the mouse's. That is today's behaviour, not a regression.

It does not cover a second top-level session in a mouse's worktree in another pane. That
is ADR-0024's one-mouse-per-worktree problem, and its proposed peer check walks the same
parent chain.

## Alternatives

**Record the mouse's session id at `SessionStart`, and accept a stop only from it.** This
fails on the bug itself. A nested `claude` and the person restarting `claude` in the same
pane both arrive as a fresh `startup` in the mouse's worktree and pane, so the record
cannot tell which one to keep. `/clear` hands the mouse a new id as well. Telling them
apart needs the process tree anyway.

**Read a variable the parent session sets.** Claude Code sets `CLAUDE_CODE_SESSION_ID`
and `CLAUDE_PID` for its children, but a nested `claude` overwrites both for its own
hooks. Nothing the nested hook sees points back to the parent.

Changed on 2026-10-13: there is no `SessionStart` hook to silence
(ADR-0088).

Changed on 2026-10-14: a nested session starts without the mouse's deny list, which is a
launch flag (ADR-next-a-mouse-starts-in-bypass-mode).
