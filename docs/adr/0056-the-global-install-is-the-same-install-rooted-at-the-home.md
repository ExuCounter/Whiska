# The install is per-repo by default, and the global install is the same install rooted at the home

`whiska init` writes the repo's own `.claude/` — the hook shim and the three hook entries
in `settings.json` — and it is checked into git, so anyone who clones the repo and has
Whiska installed gets the same hard rules. That is the default, and the only arrangement
in which they travel to someone else's machine. `whiska init --global`
writes the identical relative paths under `~/.claude` instead, for a repo that cannot
carry a committed `.claude/`: one the person does not own, or whose owners will not take
another tool's hooks. An uncommitted file is in no worktree git creates, so without the
global install every mouse spawned there would start with none of the hooks.

| | `whiska init` | `whiska init --global` |
| --- | --- | --- |
| the shim | `.claude/hooks/whiska.sh` | `~/.claude/hooks/whiska.sh` |
| the hooks | `.claude/settings.json` | `~/.claude/settings.json` |

A scope is a root and nothing else: `Whiska.Install` takes it as an argument, and the
merge and the idempotency are one implementation. Nothing in the hooks is repo-specific —
which worktree a hook fires in comes from where the session started (ADR-0053) against the
`worktrees/<branch>` layout — so a global hook in a repo with no house finds no mouse and
writes nothing. What stays per repo is the house under `.git/whiska`, never committed
anyway, and the optional `## Finish` heading, which only the repo can write. The hook
command differs by one thing: `$CLAUDE_PROJECT_DIR` names the repo, so the global copy
names `$HOME`.

## The repo's copy wins, and the global one stands down

Claude Code merges the hook arrays from both files, so a repo carrying its own install
would fire every hook twice: two denials for one tool call, two doorstep entries for one
finished turn, the same question delivered twice. So the global shim exits before
resolving anything when the repo both **has** `.claude/hooks/whiska.sh` and **wires** it
in its own `settings.json` or `settings.local.json`. Both halves are required, and that is
the security of it: a settings file is text the repo ships, so checking only for the
string would let any cloned repo switch Whiska's containment off inside itself. A repo
that has the shim and wires it is a repo that ran `whiska init`. The check greps rather
than parsing, since a hook cannot assume `jq`, and tests `-f` rather than `-r`, because
`-r` is true of a FIFO and grep on one with no writer waits for ever.

One case it does not catch: a per-repo entry older than the shim (ADR-0035) names the
binary directly and has no `whiska.sh`, so both hooks fire. `whiska doctor` fails such a
repo by name with `whiska init` as the fix.

So `whiska init` never refuses where the other scope is installed: a team that wants the
hooks committed commits them, on a machine that also has the global install.

The global shim also skips what it could never deny. It runs on most of every session's
tool calls in every repo on the machine, measured at ~143 ms a call, while `PreToolUse`
allows outright outside a `worktrees/<branch>/` folder. So for a `pre-tool-use` whose
`CLAUDE_PROJECT_DIR` is not inside a worktree it exits in ~5 ms. It reads that variable
because it is fixed for a session's life, and does nothing when it is unset; `Stop` never
takes this path, since a question lost is worse than a turn slowed.

## Whiska installs no skill

Creating a mouse and taking it down are `whiska spawn` and `whiska drop`, and everything
else a session is told is its brief (ADR-0088). The half of the
protocol that creates a mouse and the half that tracks it have to agree about the worktree
layout, the marker's spelling (ADR-0009) and where a question is read from, and in one
program they cannot drift: the person's dotfiles once carried their own copy of a
`spawn-worktree` skill, which sat 48 lines behind Whiska's for weeks, so every session
spawned anywhere skipped the shape step.

`whiska init` takes out what an older install put under its root. Each skill an older
Whiska wrote goes where it is a plain file reached through no symlink, and its folder once
nothing else is in it; one reached through a symlink is the person's, so it stays and init
names it, for them to delete where it lives. A `SessionStart` entry of Whiska's goes from
`settings.json`, and anyone else's stays.

## Writes go through a symlink, never over it

`~/.claude/settings.json` and `~/.claude/hooks` are commonly symlinks into a dotfiles
repo. Replacing a link with a plain file disconnects that repo silently. So every write
opens the path and truncates it, which follows the link and changes the target in place;
`whiska init --global` prints where each change landed, since the person's next move is to
commit it in the repo that owns the link. `whiska uninstall` names a symlinked file and
leaves it where it is, as `init` does an older skill — any segment below the root counts,
because a folder such as `~/.claude/skills` is usually one link rather than a link per
file.

## Uninstall

`whiska uninstall`, and `--global`, mirror `init` and are how a repo is handed over to the
global install: the hook entries, the shim and any skill an older install wrote go, and
nothing else is touched. The house stays: ADR-0007 is about records.

## Considered options

- **Global hooks as the default.** Zero setup per project, but the hard rules would not
  travel with a shared repo.
- **Refuse `init` where the other scope is installed.** Rejected: a team wanting the hooks
  committed should be able to, and a teammate without the global install is unaffected.
- **A second copy of the worktree procedures, kept in dotfiles.** Two copies drift; one
  program cannot.
- **Replace a symlinked file.** The dotfiles repo keeps receiving edits that never reach
  Claude Code again, with no error to say why.

## Consequences

- Per-repo is the default and `--global` the weaker choice, for repos where committing is
  not on offer.
- The table is load-bearing: a new file the installer writes needs a home in both scopes,
  or the global install is quietly missing a piece. `whiska doctor` reports the global
  install's pieces separately — the hooks that enforce, deliver and hand a mouse its
  answer (ADR-0080), and any skill or `SessionStart` entry an older install left
  (ADR-0038).
- The trust boundary moved with the install. Everything `--global` writes runs in every
  repo the person opens, including ones they are only reading; the stand-down and the
  early exit are controls, not conveniences.
- `Whiska.Install` reads the filesystem, where it was pure values plus one write.

Folded in on 2026-10-08: 0016, 0046 (their text is in git history).

Changed on 2026-10-13: the install writes no skill and no `SessionStart` entry, and takes
out the ones an older install wrote (ADR-0088).
