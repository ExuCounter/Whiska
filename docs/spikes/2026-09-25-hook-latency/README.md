# Spike: how fast can the PreToolUse hook be?

**Date:** 2026-09-25 · **Outcome:** [ADR-0033](../../adr/0033-the-hook-client-is-native-not-elixir.md)

Not production code. This is the throwaway that produced ADR-0033's numbers, kept so the
measurement can be re-run and argued with rather than taken on trust.

## The question

The `PreToolUse` hook runs before every tool call — hundreds to thousands of times per
session — and pays full process startup each time. Is Elixir's startup cost actually a
problem, and how much better can it get?

## Numbers

Apple silicon, macOS 25.4 (Darwin 25.4.0), Erlang/OTP 28 erts-16.1.1, Elixir 1.19.0.

| What runs | Runs | Per invocation |
|---|---|---|
| `elixir -e ':ok'` — bare VM boot, nothing loaded | 20 | **171 ms** |
| `bash -c true` | 200 | 4.05 ms |
| `/usr/bin/true` — tiny native binary | 200 | 1.45 ms |
| `hook.c` — the real v0.0.1 decision, payload piped in | 500 | **2.06 ms** |

## Reproducing

```sh
cc -O2 -o hook hook.c

# Elixir floor
/usr/bin/time -p bash -c 'for i in $(seq 20); do elixir -e ":ok"; done'

# Native spawn floor
/usr/bin/time -p bash -c 'for i in $(seq 200); do /usr/bin/true; done'

# The real thing, run from inside a worktree
WT=/path/to/repo/worktrees/some-branch
PAYLOAD="{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$WT/lib/x.ex\"}}"
cd "$WT" && /usr/bin/time -p bash -c \
  "for i in \$(seq 500); do printf '%s' '$PAYLOAD' | ./hook >/dev/null; done"
```

## What hook.c does

The whole v0.0.1 rule, natively: read the PreToolUse payload from stdin, derive the
worktree root from cwd (walk to the `/worktrees/<branch>` segment), pull `file_path` out of
the JSON, and emit a deny verdict if it falls outside. Verified against three cases — an
edit inside the worktree (allowed), an edit in the main checkout (denied), and a `Bash`
call with no file path (allowed).

## Known limits, stated so nobody mistakes this for a starting point

- **The JSON "parsing" is `strstr`.** It finds the first `"file_path"` and reads to the next
  quote. An escaped quote inside a path, or the string appearing somewhere else in the
  payload, defeats it. A real implementation needs an actual JSON parser.
- **No socket.** The finished hook talks to the owl; this decides locally, which is only
  correct because v0.0.1's one rule happens to need no state.
- **No SQLite, no `mouse_id` minting.** v0.0.1's real hook does both.
- **C was chosen because `cc` is always present.** ADR-0033 leaves C vs Zig open; the lean
  is Zig, for a single static binary with no library dependencies.
