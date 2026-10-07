# The hook asks the owl over a socket, from bash

*Rewritten 2026-10-07.* This record said the hook would become a native binary, in C or
Zig, written once the owl existed. The owl has existed for weeks, the native hook was
never written, and the person dropped it: the hook is the shell shim it already was,
asking the running owl over a Unix socket, with the escript behind it for when the owl
does not answer. What the old record measured is kept below, because it is still why the
escript must not be the hot path.

## The problem it solves

Whiska's hooks run as fresh processes. `PreToolUse` fires before every `Write`, `Edit`,
`MultiEdit`, `NotebookEdit` and `Bash` call a mouse makes — hundreds to thousands of
times a session — and an escript pays a whole Erlang VM boot before it runs a line. The
owl is already running, already has the code loaded, and knows the answers.

## Decision

- **The shim asks the owl first.** After its early exits (the prompt fast path,
  `session-start` outside herdr, the global copy standing down, and the global
  `pre-tool-use` outside a worktree), the committed shim reads the payload and sends it to
  `~/.whiska/hook.sock` with `nc -U`: the hook's name, the few environment variables the
  hooks read (`HERDR_ENV`, `HERDR_PANE_ID`, `CLAUDE_PROJECT_DIR`, `HOME`, `PWD`), and the
  payload. The owl runs the very modules `whiska hook <name>` runs (`Whiska.Owl.Hooks`)
  and sends back `ok <status>` and what that command would have printed.
- **Anything but an answer goes to the escript.** No socket, no `nc`, a socket file left
  by a crashed owl, an owl that takes the call and says nothing for two seconds, an owl
  too old to know the hook: the shim runs today's binary-and-runtime path with the payload
  it already read. A dead owl changes nothing about what any hook decides; it only costs
  the quarter second it always did. ADR-0036 is amended to match.
- **The environment is the hook's, never the owl's.** Every hook module takes the
  environment as an argument. An owl started by hand in the main session's pane inherits
  that pane's id, and read from there every mouse would be the main session: every edit
  allowed, every question dropped (ADR-0053).
- **Each hook gets its own connection to its house**, never the one VM-wide
  `Whiska.Repo` name. The owl answers hooks for several repos at once, and a shared name
  turns the second into "could not read this mouse's mode — assuming build". Measured,
  borrowing the open house's own connection would save 2.6 ms of the 16; it would also
  queue every hook behind the house's own delivery work on a single-connection pool, so
  it is not done.
- **A house the owl cannot reach is left to the escript.** When the owl cannot open a
  mouse's house — its file descriptors run out, its database is locked — or cannot write
  a finished turn onto the doorstep, it hangs up without answering. Answering would put
  its own weaker fallback ("assuming build") in place of a fresh escript's real decision.
- **The shim trusts only a socket the person owns** (`[ -O ]`, a shell builtin). Its
  answer is final, so a socket another account bound first — under a `WHISKA_HOME` in a
  shared folder — would otherwise decide every hook.
- **The socket is private and believes its caller**, as the escript believes its stdin.
  It is owner-only, so anything that reaches it is the person's own account — which can
  already run `whiska hook stop` with any payload it likes. ADR-0024's peer-process check
  guards what a request can *approve*; a hook request approves nothing. Its format is
  versioned (`hook 1 …`) because committed shims outlive the owl they were written
  against, and it is not documented for anyone else: `owl.sock` is the interface scripts
  use (ADR-0025).
- **The native hook is dropped**, not deferred. Bash and `nc` are on every machine the
  shim already runs on, and there is no second toolchain to build and ship.

## Numbers

Measured 2026-10-07 on the development machine: Apple silicon, macOS 25.4, Erlang/OTP 28
erts-16.1.1, Elixir 1.19.0, the stock `/bin/bash` 3.2, with this branch's prod escript
and an owl running the same code. Reproduce with
`docs/spikes/2026-10-07-socket-hook/bench.sh`.

| What runs | Per invocation |
|---|---|
| `bash -c true` (200 runs) | 2.4 ms |
| `pre-tool-use` through the shim, the owl answering (200 runs) | **16.6 ms** |
| `pre-tool-use` through the shim, no owl: the escript (20 runs) | 245.6 ms |
| `stop` through the shim, the owl answering (200 runs) | **15.8 ms** |
| `stop` through the shim, no owl: the escript (20 runs) | 238.8 ms |

About 15× on the path that runs most often. A session making a thousand tool calls spends
about 16 seconds in hooks rather than four minutes.

The 16 ms is not the 5–10 ms expected when this was decided. It breaks down as bash
starting (2.4 ms), `nc` itself (about 7 ms — a connect that fails outright still costs
that), and the owl's own work (about 3 ms, 2.6 ms of it opening and closing the house's
database for the request); the rest is the shim's own forks to read stdin and capture
the answer.

The record this replaces measured the floors it argued from, and they still hold: a bare
`elixir -e ':ok'` boots in 171 ms, and a 35-line C hook doing v0.0.1's one rule took
2.06 ms. That spike is kept at `docs/spikes/2026-09-25-hook-latency/`, as the number
behind the option not taken.

## Consequences

- **`settings.json` did not change**, exactly as ADR-0035 promised: only the shim did.
  A repo that never re-runs `whiska init` keeps its old shim, which never asks the owl and
  keeps working through the escript.
- **Two ways in, one piece of logic.** The owl and the escript run the same modules, so
  there is still one place each rule is decided. The tests drive the hook socket through
  the real shim under `/bin/bash` 3.2 — the oldest bash a hook may land in, and one that
  misreads a `case` written inside `$( )`.
- **The doctor probes both.** Its hook probes point the hook socket at nothing, so they
  keep testing the installed binary every hook falls back on; a separate `sockets` line,
  shown only while an owl runs, says whether the owl answers. Never a failure: hooks that
  fall back still do their job (ADR-0038).
- **Linux takes `nc` as it finds it.** OpenBSD netcat speaks Unix sockets and honours
  `-w` as the two-second limit. ncat speaks them too, but its `-w` bounds only the
  connect: an owl frozen while the kernel still queues connections holds each hook until
  the owl's own request limits end it, or Claude Code's hook timeout does. GNU netcat has
  no Unix sockets, and a machine with only that takes the escript path for every hook.
- **Warnings the hook modules print go to the owl's log** when the owl answers. Claude
  Code never showed an exit-0 hook's stderr anyway (ADR-0035).

## Two cheap wins that still apply

- **Narrow the matcher.** Only `Write|Edit|MultiEdit|NotebookEdit|Bash` run the hook;
  `Read`, `Grep` and `Glob` never do. Not running at all beats running fast.
- **Decide locally where nothing needs the owl.** The prompt hook still leaves from the
  shell when no answer flag is set, and `session-start` outside herdr never asks anyone.

## Considered options

**A native binary (this record's old decision).** About 2 ms, and one more toolchain in
the project and in the brew formula, written against a protocol to the owl that did not
exist yet. Dropped by the person on 2026-10-07: 16 ms already removes almost all of the
cost, and bash needs nothing built.

**Socket only, no escript behind it.** Fails open when the owl is down: no sniff mode, no
containment, no hold, no rules at session start, and every finished turn lost. Rejected.

**Keep `Stop` off the socket.** Bash would write the raw payload to the doorstep and the
owl would parse it later. That keeps ADR-0036's sentence literally true, but the check for
a subagent still out (ADR-0052) would read the transcript seconds late, after it may have
moved on. Rejected.
