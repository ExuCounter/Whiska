# The committed hook command names only a shim

The hook entry in the repo's own `.claude/settings.json` is committed so the rules travel
with the repo (ADR-0056). The first implementation did not deliver that: it wrote the
Erlang runtime and the Whiska binary into the command as absolute paths, resolved at
install time:

```
/Users/someone/.asdf/installs/erlang/28.1.1/bin/escript /Users/someone/.local/bin/whiska hook pre-tool-use
```

That file works on exactly one machine. It names a home directory nobody else has, pins an
Erlang version that breaks on the next upgrade, and publishes a username into a shared
repo. Installing into three repos on one machine produced two different runtime paths,
because the escript's `#!/usr/bin/env escript` shebang resolves through the version
manager against the directory `init` happened to run in.

So **the committed command names only a shim, checked in beside it, and every
machine-specific lookup happens in that shim at run time:**

```
bash "$CLAUDE_PROJECT_DIR/.claude/hooks/whiska.sh" pre-tool-use
```

The shim asks the owl over its hook socket first (ADR-0033); when nothing answers it finds
the binary on `PATH`, then at `~/.local/bin/whiska`, and `escript` on `PATH`, then via
`asdf which`. `WHISKA_BIN`, `WHISKA_ESCRIPT` and `WHISKA_HOOK_SOCKET` override each
without editing the file.

## Considered options

**`$HOME` in the paths.** Removes the username and costs nothing, but still pins the exact
Erlang version and assumes both asdf and `~/.local/bin`.

**Gitignore `settings.json` and treat the hook as per-machine config.** Honest, and zero
code. Rejected because the rules would stop travelling with the repo, which is the reason
hooks are per-project.

**Bare `whiska hook pre-tool-use`, relying on `PATH`.** Rejected on measurement: `escript`
is not on a bare `PATH`, and a hook does not necessarily inherit an interactive shell's.
This is the trap recorded in `6dfb2de`, and it is still real.

## Consequences

**A `bash` wrapper is accepted.** An earlier rule held that spawning a shell to spawn the
real thing costs about 4 ms, which mattered against a native hook's budget. Measured over
20 runs each on the real worktree path with SQLite open: 214.5 ms unwrapped, 204.7 ms
wrapped — inside the noise of BEAM boot. The hook is bash by design now, and its 2.4 ms is
the smallest part of the 16 ms it costs when the owl answers.

**`settings.json` stops changing.** When the hooks moved onto the owl (ADR-0033) only the
shim changed; every repo that had committed the hook kept working without re-running
`init`, and an older committed shim never asks the owl and goes on through the escript. An
Erlang upgrade likewise needs no reinstall.

**`init` writes two files**, and both must be committed. It migrates in place: an entry is
recognised as Whiska's by its command containing either `hook pre-tool-use` or the shim
path, so re-running `init` over an old absolute-path install replaces it rather than
stacking a second entry beside it.

**The shim fails open, and says so where it costs something.** If no Whiska binary is
found, or the one found will not run, it writes to stderr and allows the call. Denying
would brick every tool call in a session over a missing install — the same trade
`Whiska.Hook.PreToolUse` makes on a malformed payload, and again when it cannot read a
mouse's mode. The shim cannot read the mode either, so it cannot deny only a sniff mouse.

It exits 1 when the session is in a worktree and Whiska is set up for this repo on this
machine — the repo's house exists, or the binary was found. Everywhere else it exits 0.
Measured on Claude Code 2.1.285: an exit-0 hook's stderr is filed as a success and never
shown, so a shim that always exited 0 failed open in silence — sniff mode and containment
off, and a mouse's last message never reaching the doorstep. Exit 1 is shown as a hook
error, still lets the call through, and on `Stop` ends the turn without looping. Exit 2
was rejected: on `PreToolUse` it denies, on `Stop` it keeps the turn going. The exit-0
cases are the ones where nothing is lost — a session outside a worktree, where both hooks
are no-ops, and a committed hook that reached a machine where Whiska was never set up,
which must not light up every tool call for a colleague. The complaint goes to stderr in
every case, which is what `whiska doctor`'s probe reads.

**One more moving part to keep honest.** The shim is shell, so it is not covered by the
Elixir suite beyond its contents being asserted; its resolution logic is verified by
running the installed hook end to end rather than by unit test.
