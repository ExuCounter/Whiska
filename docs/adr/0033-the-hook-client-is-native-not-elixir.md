# The hook client is a native binary, not Elixir

The `PreToolUse` hook fires before **every** tool call a mouse makes — hundreds to
thousands of times per session. Whatever Claude Code runs there pays full process startup
each time, and Elixir cannot win that race: the BEAM has to boot before any code runs, and
no amount of optimisation inside the program removes it.

Measured on the development machine (Apple silicon, macOS 25.4, Erlang/OTP 28 erts-16.1.1,
Elixir 1.19.0):

| What runs | Per invocation |
|---|---|
| `elixir -e ':ok'` — bare VM boot, nothing loaded (20 runs) | **171 ms** |
| `bash -c true` (200 runs) | 4.05 ms |
| A tiny native binary (200 runs) | 1.45 ms |
| A 35-line C hook doing the real v0.0.1 decision, payload piped in (500 runs) | **2.06 ms** |

85× on the thing that runs most often. At 171 ms, a session making a thousand tool calls
spends nearly three minutes doing nothing but starting the VM — invisible as any single
pause, felt only as the mouse being generally sluggish.

So: **Elixir owns the owl. A native binary (C or Zig, both already present on the dev
machine) owns the hook.**

## Why this costs less than it looks

In the finished system the hook is a messenger, not a decision-maker. It reads the payload,
sends "mouse X wants tool Y on target Z" down the repo's Unix socket, reads back
allow/deny, prints it, exits. Every actual judgment — checks, push approval, question
creation, the whole asynchronous flow of ADR-0011 — lives in the owl. There is no Elixir
advantage to give up in a program with no concurrency, no supervision, and no state.

The socket roundtrip itself is ~0.1 ms, irrelevant beside process spawn. For the activity
telemetry of ADR-0026 (last-tool-call excerpt), which wants to see every call, the hook
should write a fire-and-forget datagram rather than wait for a reply it does not need.

## Considered options

**One language everywhere.** Rejected on the measurement. Using Elixir for both means one of
the two jobs gets the wrong tool, and it is the hot one that suffers.

**Going native in v0.0.1.** Rejected, deliberately. v0.0.1's hook is temporarily fatter than
the final one: with no owl yet, it also opens SQLite and mints the `mouse_id` (ADR-0030).
Writing those in C now means deleting them when the owl takes both jobs over. The hook
shrinks to its final messenger shape exactly when the owl arrives, so that is the moment to
write it natively — once, in its final form, rather than twice.

## Consequences

**v0.0.1 stays an Elixir escript and ships as specified.** Its job is proving the plumbing,
and 171 ms is survivable for a slice being tested rather than lived in. The build session
should still report the real escript cold-start with Ecto and SQLite loaded, since 171 ms is
a floor, not the figure.

**The project carries two languages** from the owl slice onward — more toolchain, more to
build and ship in the brew formula. Accepted knowingly.

**Two cheap wins that apply regardless of language**, worth taking when the hook is
installed for real:

- **Narrow the matcher.** Claude Code hook matchers filter by tool name. Register only for
  the tools the rules actually concern (`Write|Edit|MultiEdit|NotebookEdit`, plus `Bash`
  once push detection and sniff mode need it) rather than `*`. `Read`, `Grep` and `Glob` are
  a large share of all tool calls; not running at all beats running fast.
- **No `bash` wrapper.** Point the hook command straight at the binary. Spawning `bash` to
  spawn the real thing costs 4 ms — more than twice the entire native hook.

**Decide locally where the rule allows it.** The worktree-containment rule is pure path
arithmetic and needs no owl at all. A hook that can answer without opening a socket should.
