# Whiska

An Elixir/OTP coordinator that manages Claude Code worker sessions ("mice") running in
isolated git worktrees.

`CONTEXT.md` is the glossary — **Whiska**, **mouse**, **mouse_id**, **question**,
**house**, **owl**, **build/sniff mode**. `docs/adr/` records why things are the way they
are, and those decisions are binding.

## Status: v0.0.1 — the first real slice

The smallest end-to-end piece that proves the core plumbing: identity, storage, one
enforced rule (ADR-0030). This is a plain CLI, **not** the owl — no supervision tree, no
long-running process, no cross-repo commands, no `checks.yml`, no push approval, and no
contact with herdr at all. Those arrive in later slices.

```
mix deps.get
mix test          # 68 tests
mix escript.build # produces ./whiska
```

### What it does

`whiska hook pre-tool-use` reads a Claude Code `PreToolUse` event as JSON on stdin and
either stays silent (allow) or prints a deny decision as JSON on stdout. It always exits
0 — the decision travels in the JSON body, and a non-zero exit would read to Claude Code
as the hook itself having failed.

On the first invocation inside a worktree it mints an opaque `mouse_id`, writes it to
`.whiska-mouse` at the worktree root (ADR-0002), and records the mouse in this repo's
house at `<main-checkout>/.git/whiska/whiska.db`.

**The one enforced rule:** a mouse may not edit the main checkout (ADR-0013). Only tools
that name a literal target path are policed — `Write`, `Edit`, `MultiEdit` (`file_path`)
and `NotebookEdit` (`notebook_path`) — so the rule never produces a false denial.

**Known hole, recorded on purpose:** `Bash` is not policed in this slice, so `sed -i`,
`cat > file` and `git -C <main-checkout>` can still reach the main checkout. Deciding
mutating-vs-reading for an arbitrary shell string is the same judgment sniff mode needs
(ADR-0018), and it gets built once, properly, in that slice rather than badly here.
Reads are not policed either, and should not be — the rule is about containing *changes*,
not a sandbox.

### Installing the hook

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Write|Edit|MultiEdit|NotebookEdit",
        "hooks": [{ "type": "command", "command": "/absolute/path/to/whiska hook pre-tool-use" }]
      }
    ]
  }
}
```

If `escript` is on your `PATH` via a version manager (asdf, mise, kerl), spell out the
absolute path to the real `escript` binary instead of relying on the shim:

```json
"command": "/Users/you/.asdf/installs/erlang/28.1.1/bin/escript /path/to/whiska hook pre-tool-use"
```

This matters more than it looks. A `whiska` built by `mix escript.build` starts with
`#!/usr/bin/env escript`, so it only runs if `escript` is findable on `PATH` — and a hook
does not necessarily inherit your interactive shell's `PATH`. With a stripped environment
the shim version fails outright (`env: escript: No such file or directory`) while the
absolute path works. It is also ~12 ms faster, since an asdf shim is itself a bash script.
The cost is that the Erlang version is baked into the path, so re-point it after an Erlang
upgrade. A `mix release` bundles its own Erlang runtime and sidesteps this entirely, which
is what the eventual `brew install whiska` of ADR-0001 will ship.

Two more details in there are deliberate, both from ADR-0033:

- **The matcher is narrow, not `*`.** `Read`, `Grep` and `Glob` are a large share of all
  tool calls and none of them can trip this rule. Not running at all beats running fast.
  `Bash` joins the list when push detection and sniff mode need it.
- **No `bash` wrapper.** The command points straight at the binary. Spawning `bash` to
  spawn the real thing costs ~4 ms — more than twice what the entire hook will cost once
  ADR-0033's native client replaces this one.

### Cold start

Measured on the development machine (Apple silicon, macOS 25.4, OTP 28, Elixir 1.19),
30 runs each:

| What runs | Per invocation |
|---|---|
| Bare `elixir -e ':ok'` | 177 ms |
| `whiska --version` — escript boot floor | 126 ms |
| **`whiska hook pre-tool-use` — the real job, SQLite included** | **~220 ms** |
| First run ever, which also unpacks the bundled SQLite library | 627 ms, once |

Roughly 126 ms of that is the BEAM booting before any code runs, and the rest is
loading Ecto, db_connection and exqlite. The SQLite work itself — open, migrate, upsert —
is under 2 ms. Nothing inside the program can remove the first 126 ms, which is why
ADR-0033 moves the hook client to a native binary when the owl arrives, and why the
narrow matcher above matters more than it looks: `Read`, `Grep` and `Glob` never pay it.

### Why the binary is 3 MB

An escript is a zip archive. It carries no `priv/` directories, and native code cannot be
`dlopen`ed out of a zip in any case — so SQLite's 1.6 MB native library travels as bytes
embedded in `Whiska.BundledNIF` and is unpacked to `~/.cache/whiska/exqlite-<vsn>/` on
first run. That is the only reason ADR-0030's "single binary" and ADR-0028's "real
SQLite" can both hold. It is scaffolding with a known end: when ADR-0033's native hook
client arrives, the hook stops touching storage entirely and this module is deleted whole.
