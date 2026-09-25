# Readiness checks come from a per-repo checks.yml, with no tool hardcoded

"Is this worktree actually done?" is not answered by asking the mouse — a mouse marking
itself `done` is just its own opinion. What decides is whether a small set of repo-defined
checks pass. Those checks live in `.whiska/checks.yml`, scaffolded by `whiska init`: a
flat list of named shell commands (`test: mix test`, `lint: mix credo`). The person writes
it, the same way they write the `CLAUDE.md` block. No-mistakes, a bare `npm test`, a
Makefile target — each is one line, and none of it is hardcoded into Whiska.

## Consequences

An empty or missing file means no checks configured: Whiska does only its edit/push
enforcement and nothing more. That is what lets a repo using no gate tool today work with
zero friction.

All configured checks run in parallel, since they are independent commands with no
ordering dependency — six checks cost about as long as the slowest one, not the sum.
Whiska reports exactly which ones failed, with their output, not a pass/fail blob.

If a real automated review tool is adopted later, it slots in as one more line and Whiska
stays exactly as dumb as it is today.

Environment and secrets are plain inheritance, stated honestly: a mouse and its checks get
normal ambient environment inheritance like any child process. There is no secret scanning
or redaction of what a mouse commits, logs, or reports back — the same honest limit
firstmate has. If it becomes a real problem, that is a concrete feature to add then.
