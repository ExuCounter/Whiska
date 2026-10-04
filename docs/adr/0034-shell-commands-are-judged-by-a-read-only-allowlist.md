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

**Containment reads paths by pattern, and stops where the text stops.** Each command in a
line is judged against where the shell stands when it runs — the hook payload's `cwd`,
moved by any literal `cd` or `pushd` earlier in the line, and put back when a `( … )`
subshell closes. A mutating command run from inside the main checkout is denied whatever
it names, so a bare `rm CONTEXT.md` after a `cd` is caught. The paths judged are every
literal absolute path anywhere in the text, with quotes and backslashes dropped first —
glued to `2>` or `of=`, split by `my"re"po`, or inside a nested `bash -c` — and every
relative path-like word, with `$HOME`, `${HOME}` and `~` expanded. From outside the
worktree every bare word counts, and a path is denied when it is the main checkout or a
folder above it, so `cd .. && rm -rf repo` is caught too.

What it does not catch, on purpose: any other variable, a path built by a substitution or
a glob, a `cd` to a computed directory or one inside a nested shell, and a program written
into the worktree and run. Those are allowed — the rule catches honest mistakes rather
than a mouse set on escaping, which no text check can (ADR-0024's honest limit). What it
denies that it need not: a mutating command whose text quotes the main checkout's
absolute path, such as a commit message, and any mutating command run while standing in
the main checkout, wherever it writes. Added 2026-10-04.

**`git` is judged per subcommand.** Only an explicit list — `log`, `diff`, `status`,
`show`, `blame`, `rev-parse`, and similar — is read-only. `branch`, `tag`, `stash`,
`config`, `remote` and `worktree` all have mutating forms and are treated as mutating
whole, rather than trying to read their flags.

**The allowlist is maintenance.** A read-only tool missing from it produces a false
denial until someone adds it. That is accepted: the failure is visible, recoverable, and
lands on a mouse rather than silently letting a write through.

**Quoting is read before operators are.** Operators are located against a masked copy of
the command, in which quoted spans and backslash-escaped characters are replaced by filler
of the same byte length. A `>` or a `|` inside a search pattern is an ordinary character,
not a redirect or a pipe — without the mask, `rg "foo|bar" lib/` and `grep -r "=>" lib/`
are both denied, and in an Elixir repo the second is routine. Judgment is likewise made on
tokens rather than on the raw string, so a flag or filename that merely contains `exec` or
`eval` is not mistaken for the command.

**`find` and `awk` are judged like `git`, per what they actually do.** `find` is read-only
until an action writes (`-delete`) or runs something (`-exec`, `-execdir`, `-ok`), and the
command after `-exec` is then judged on its own — which lets a read-only sweep through
while `find . -exec rm {} \;` stays denied. `awk` is read-only unless its program
redirects with `>`, calls `system()`, or pipes its output, all of which sit inside a
quoted argument where the mask deliberately hides them from the redirect check.

**Being on the list does not make every use of a command read-only.** A listed command
is still judged by what its own flags, operands and environment make it do, the way
`git`, `sed`, `find` and `awk` already were. An output file (`sort -o`, `xmllint
--output`, `tree -o`, `less -o`, `git diff --output`), an in-place edit (`yq -i`), a
second operand that is the output file (`uniq a b`, `xxd a b`), a flag that names a
program (`rg --pre`, `ag --pager`, `man -P`, `fd -x`, `git grep -O`, `git ls-remote
--upload-pack`), `git -c` and `--config-env`, and a variable that names a program
(`GIT_*`, `LESS*`, `*PAGER`, `RIPGREP_CONFIG_PATH`) each make the command mutating.

Where it is unclear, it leans toward denying: a long flag counts at any prefix of a
writing name, since getopt accepts `sort --out=x`, and a flag whose value is not known
to the code has that value counted as an operand, so `uniq` with an unknown flag can be
denied but never let through. Each command is read only as far as needed — which
letters write, which take a value — never parsed in full. Added 2026-10-04.

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
