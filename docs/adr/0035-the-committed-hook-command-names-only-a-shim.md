# The committed hook command names only a shim

ADR-0016 puts the hook in the repo's own `.claude/settings.json` and checks it into git,
"so anyone who clones the repo and has Whiska installed gets the same rules
automatically". The first implementation did not deliver that. It wrote the Erlang runtime
and the Whiska binary into the command as absolute paths, resolved at install time:

```
/Users/someone/.asdf/installs/erlang/28.1.1/bin/escript /Users/someone/.local/bin/whiska hook pre-tool-use
```

That file works on exactly one machine. It names a home directory nobody else has, pins an
Erlang version that breaks on the next upgrade, and publishes a username into a shared
repo. Installing into three repos on one machine produced two *different* runtime paths,
because the escript's `#!/usr/bin/env escript` shebang resolves through the version
manager against the directory `init` happened to run in.

So: **the committed command names only a shim, checked in beside it, and every
machine-specific lookup moves into that shim where it happens at run time.**

```
bash "$CLAUDE_PROJECT_DIR/.claude/hooks/whiska.sh"
```

The shim finds the binary on `PATH`, then at `~/.local/bin/whiska`; it finds `escript` on
`PATH`, then via `asdf which`. `WHISKA_BIN` and `WHISKA_ESCRIPT` override either without
editing the file.

## Considered options

**`$HOME` in the paths.** Removes the username and costs nothing, but still pins the exact
Erlang version and assumes both asdf and `~/.local/bin`. It fixes the disclosure without
fixing the portability problem underneath it, and ADR-0016's promise stays false.

**Gitignore `settings.json` and treat the hook as per-machine config.** Honest, and zero
code. Rejected because it abandons ADR-0016 outright — the rules stop travelling with the
repo, which was the whole reason hooks are per-project rather than global. If this is ever
wanted, ADR-0016 gets rewritten rather than quietly ignored.

**Bare `whiska hook pre-tool-use`, relying on `PATH`.** Rejected on measurement: `escript`
is not on a bare `PATH`, and a hook does not necessarily inherit an interactive shell's.
This is the trap recorded in `6dfb2de`, and it is still real.

## Consequences

**This reverses the "no `bash -c` wrapper" rule**, which held that spawning a shell to
spawn the real thing costs about 4 ms — "more than twice what ADR-0033's eventual native
hook will cost in total". True, and irrelevant to the hook that exists. Measured over 20
runs each on the real worktree path with SQLite open: **214.5 ms unwrapped, 204.7 ms
wrapped.** The wrapper is inside the noise of BEAM boot. The rule was written against the
native hook's budget and applied to the escript's, where it bought nothing and cost
portability.

**`settings.json` stops changing.** When ADR-0033's native binary replaces the escript,
only the shim changes — every repo that has already committed the hook keeps working
without re-running `init`. An Erlang upgrade likewise needs no reinstall, which the
absolute path did.

**`init` now writes two files**, and both must be committed. It also migrates in place: an
entry is recognised as Whiska's by its command containing either `hook pre-tool-use` or
the shim path, so re-running `init` over an old absolute-path install replaces it rather
than stacking a second entry beside it.

**The shim fails open.** If no Whiska binary is found it writes to stderr and exits 0,
allowing the call. Denying would brick every tool call in a session over a missing
install — the same trade `Whiska.Hook.PreToolUse` already makes on a malformed payload.

**One more moving part to keep honest.** The shim is shell, so it is not covered by the
Elixir suite beyond its contents being asserted; its resolution logic is verified by
running the installed hook end to end rather than by unit test.
