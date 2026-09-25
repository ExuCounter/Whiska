# Shell commands are judged by a read-only allowlist, not a mutating denylist

Two rules need to read an arbitrary `Bash` string. Sniff mode has to know whether a
command changes anything at all (ADR-0018); worktree containment has to know whether a
command changes anything *in the main checkout* (ADR-0013). Neither can be answered
exactly — a shell command is a program, and Whiska is not a shell.

So the question is which way to be wrong. **An allowlist of commands known to be
read-only, with everything else treated as mutating.** A denylist of known-mutating
commands was rejected: it leaks by construction, and the thing it leaks is precisely the
case sniff mode exists to prevent. Anything unreadable — `eval`, a command substitution,
a nested `bash -c`, an unrecognised binary — is reported as mutating rather than guessed
at.

This is the opposite balance from the rule ADR-0030 shipped in v0.0.1, which polices only
literal `file_path` arguments specifically so it can never produce a false denial. The
difference is who absorbs the mistake. There, a false denial lands on the person and
trains them to ignore the hook. Here it lands on the mouse, which can reach for `Read` or
`Grep` instead, while a single missed mutation defeats the whole mode.

## Consequences

**The build-mode `Bash` hole closes as a side effect, and cheaply.** The hole recorded in
v0.0.1 — `sed -i`, `cat >`, `git -C <main>` — is now denied when a command is *both*
mutating *and* names a path resolving into the main checkout. Gating on mutation is what
makes it tolerable: `cat <main>/CONTEXT.md` and `grep -r <main>` stay allowed, where a
plain substring match on the main-checkout path would have denied those too. Reads are
never policed, in any tool.

**`git` is judged per subcommand.** Only an explicit list — `log`, `diff`, `status`,
`show`, `blame`, `rev-parse`, and similar — is read-only. `branch`, `tag`, `stash`,
`config`, `remote` and `worktree` all have mutating forms and are treated as mutating
whole, rather than trying to read their flags.

**The allowlist is maintenance.** A read-only tool missing from it produces a false
denial until someone adds it. That is accepted: the failure is visible, recoverable, and
lands on a mouse rather than silently letting a write through.

## How a mouse gets its mode

`Mouse.mode` existed from v0.0.1 but nothing wrote it, so sniff enforcement would have
been unreachable code. `whiska mode <build|sniff>`, run inside the worktree, sets it. The
mode lives in the house keyed by `mouse_id` rather than in the marker file, so it survives
a renamed branch or a moved folder for the same reason identity does (ADR-0002), and the
marker stays the bare opaque id that ADR describes. When the owl arrives and spawns mice
directly, it sets the same column; nothing here has to change.

**An unreadable mode degrades to `build`, loudly.** `build` is the default and the common
case, and assuming `sniff` would block every edit in ordinary work over a database
hiccup. This degrades sniff to build, never to unprotected: worktree containment is pure
path arithmetic and does not consult the database at all.
