# The owl answers on two sockets: `hook.sock` for the hooks, `owl.sock` read-only for scripts

Whiska's hooks are a committed bash shim that asks the running owl over a private Unix
socket, `~/.whiska/hook.sock`, and runs the escript only when the owl does not answer. A
second socket beside it, `~/.whiska/owl.sock`, is read-only and documented: what the
person's own scripts and herdr's tab bar ask instead of starting Whiska.

## The problem

Whiska's hooks run as fresh processes. `PreToolUse` fires before every `Write`, `Edit`,
`MultiEdit`, `NotebookEdit` and `Bash` call a mouse makes, hundreds to thousands of times
a session, and an escript pays a whole Erlang VM boot before it runs a line. The owl is
already running, already has the code loaded, and knows the answers. And with several
projects worked at once, "what is waiting anywhere" needs an endpoint that is not
repo-scoped.

## The hook socket

- **The shim asks the owl first.** After its early exits (the prompt fast path,
  `session-start` outside herdr, the global copy standing down, and the global
  `pre-tool-use` outside a worktree), it reads the payload and sends it to `hook.sock`
  with `nc -U`: the hook's name, the few environment variables the hooks read
  (`HERDR_ENV`, `HERDR_PANE_ID`, `CLAUDE_PROJECT_DIR`, `HOME`, `PWD`), and the payload. The
  owl runs the very modules `whiska hook <name>` runs (`Whiska.Owl.Hooks`) and sends back
  `ok <status>` and what that command would have printed.
- **Anything but an answer goes to the escript.** No socket, no `nc`, a socket file left
  by a crashed owl, an owl that says nothing for two seconds, an owl too old to know the
  hook: the shim runs the binary-and-runtime path with the payload it already read. A dead
  owl changes nothing about what any hook decides; it only costs the quarter second it
  always did.
- **The environment is the hook's, never the owl's.** Every hook module takes the
  environment as an argument. An owl started by hand in the main session's pane inherits
  that pane's id, and read from there every mouse would be the main session: every edit
  allowed, every question dropped (ADR-0053).
- **Each hook gets its own connection to its house**, never the one VM-wide `Whiska.Repo`
  name. The owl answers hooks for several repos at once, and a shared name turns the
  second into "could not read this mouse's mode, assuming build". Borrowing the open
  house's own connection would save 2.6 ms of the 16 and queue every hook behind the
  house's delivery work on a single-connection pool, so it is not done.
- **A house the owl cannot reach is left to the escript.** When the owl cannot open a
  mouse's house or cannot write a finished turn onto the doorstep, it hangs up without
  answering, rather than putting its own weaker fallback in place of a fresh escript's
  real decision.
- **The shim trusts only a socket the person owns** (`[ -O ]`, a shell builtin). Its answer
  is final, so a socket another account bound first would otherwise decide every hook.
- **The socket is private and believes its caller**, as the escript believes its stdin. It
  is owner-only, so anything that reaches it is the person's own account, which can
  already run `whiska hook stop` with any payload. ADR-0024's peer-process check guards
  what a request can *approve*; a hook request approves nothing. Its format is versioned
  (`hook 1 …`) because committed shims outlive the owl they were written against, and it is
  not documented for anyone else.

## The owl socket

`owl.sock` answers one plain-text request line with one line, from the moment the owl
starts, owner-only:

- `waiting` → `{"version":1,"waiting":[…]}`, the rows `whiska waiting --json` prints;
- `show <id> <main_checkout>` → one question with its whole text; the checkout is needed
  because question ids are numbered per house;
- `line [hint]` → the tab bar's line, plain text;
- anything else → `{"version":1,"error":"…"}`.

`version` changes only when a field does. The format is documented in the README because
the person's own scripts depend on it. It only ever reads: `show` answers only for a house
in the open-houses record whose database is already there, so asking about a path creates
nothing. It is deliberately weaker than the per-repo socket ADR-0024 designs: it can never
approve a push or act on a mouse, so owner-only permissions are enough. herdr's tab bar
asks it (ADR-0048); `whiska waiting`, `whiska jump` and `whiska statusline` still read the
houses directly, since they start Erlang either way and that also works while the owl is
down.

The hooks have their own socket because a hook writes: it records mice, mints markers,
leaves questions on the doorstep and stamps answers taken. Putting that on `owl.sock`
would end its one property.

## Numbers

Measured 2026-10-07 on Apple silicon, macOS 25.4, Erlang/OTP 28, Elixir 1.19.0, the stock
`/bin/bash` 3.2. Reproduce with `docs/spikes/2026-10-07-socket-hook/bench.sh`.

| What runs | Per invocation |
|---|---|
| `bash -c true` (200 runs) | 2.4 ms |
| `pre-tool-use` through the shim, the owl answering (200 runs) | **16.6 ms** |
| `pre-tool-use` through the shim, no owl: the escript (20 runs) | 245.6 ms |
| `stop` through the shim, the owl answering (200 runs) | **15.8 ms** |
| `stop` through the shim, no owl: the escript (20 runs) | 238.8 ms |

About 15× on the path that runs most often: a session making a thousand tool calls spends
about 16 seconds in hooks rather than four minutes. The 16 ms is bash starting (2.4 ms),
`nc` (about 7 ms, a failed connect included), the owl's own work (about 3 ms, 2.6 ms of it
opening and closing the house's database), and the shim's own forks. A bare
`elixir -e ':ok'` boots in 171 ms, which is why the escript must not be the hot path; the
spike at `docs/spikes/2026-09-25-hook-latency/` measured the native binary not taken at
2.06 ms.

## Consequences

- **`settings.json` did not change** when the hooks moved onto the owl, as ADR-0035
  promised: only the shim did. A repo that never re-runs `whiska init` keeps its old shim,
  which never asks the owl and keeps working through the escript.
- **Two ways in, one piece of logic.** The owl and the escript run the same modules, so
  each rule is decided in one place. The tests drive the hook socket through the real shim
  under `/bin/bash` 3.2, the oldest bash a hook may land in.
- **The doctor probes both.** Its hook probes point the hook socket at nothing, so they
  keep testing the installed binary every hook falls back on; a `sockets` line, shown only
  while an owl runs, says whether the owl answers on both. Never a failure: hooks that fall
  back still do their job (ADR-0038).
- **Linux takes `nc` as it finds it.** OpenBSD netcat speaks Unix sockets and honours `-w`
  as the two-second limit; ncat bounds only the connect; GNU netcat has no Unix sockets, and
  a machine with only that takes the escript path for every hook.
- **Warnings the hook modules print go to the owl's log** when the owl answers.
- Only `Write|Edit|MultiEdit|NotebookEdit|Bash` run the hook at all, and the prompt hook
  leaves from the shell when no answer flag is set: not running beats running fast.

## Considered options

**A native binary**, in C or Zig, about 2 ms. Dropped: one more toolchain in the project
and the brew formula, for a cost 16 ms already removes almost all of.

**Socket only, no escript behind it.** Fails open when the owl is down: no sniff mode, no
containment, no hold, no rules at session start, every finished turn lost. Rejected.

**Keep `Stop` off the socket**, bash writing the raw payload to the doorstep for the owl to
parse later. The check for a subagent still out (ADR-0052) would read the transcript
seconds late. Rejected.

**One socket for both.** Rejected: the hooks write, and the read-only socket's whole value
is that it cannot.

Folded in on 2026-10-08: 0025 (its text is in git history).
