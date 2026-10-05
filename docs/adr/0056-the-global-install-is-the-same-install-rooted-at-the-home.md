# The global install is the same install rooted at the home, and the repo's copy wins

ADR-0016 made hooks and rules per-project: `whiska init` writes `.claude/` and the block
in `CLAUDE.md`, they are checked into git, and the rules travel with the repo. That holds
wherever the repo will take them.

Some repos will not. A person working in a repo they do not own, or one whose owners will
not carry another tool's hooks, cannot commit any of it — and an uncommitted file is not
in any worktree git creates, so every mouse spawned there starts with none of the rules.
The repo where the protocol matters most is the one where it cannot be installed.

So `whiska init --global` writes the same install into `~/.claude` instead.

## It is the same install, not a second one

Every path Whiska writes is the same relative path in both scopes:

| | `whiska init` | `whiska init --global` |
| --- | --- | --- |
| the block | `CLAUDE.md` | `~/.claude/CLAUDE.md` |
| the shim | `.claude/hooks/whiska.sh` | `~/.claude/hooks/whiska.sh` |
| the board | `.claude/hooks/whiska-statusline.sh` | `~/.claude/hooks/whiska-statusline.sh` |
| the hooks and the statusline | `.claude/settings.json` | `~/.claude/settings.json` |
| the skills | `.claude/skills/` | `~/.claude/skills/` |

A scope is a root, and nothing else. `Whiska.Install` and `Whiska.ClaudeMd` take it as an
argument and the merge, the `keep` semantics and the idempotency are one implementation
either way.

Nothing needs to be per-repo for this to work, because nothing in the hooks was ever
repo-specific. Which worktree a hook is firing in is derived from where the session
started (ADR-0053) against the `worktrees/<branch>` layout (ADR-0030), and the board file
is found by walking up from the directory the session is sitting in. A global hook in a
repo with no house simply finds no mouse and writes nothing. What stays per repo is the
house under `.git/whiska` — which was never committed anyway — and the optional `## Finish`
heading, which is the repo's to write because only the repo knows what green means.

Two differences, each forced:

- **The hook command.** `$CLAUDE_PROJECT_DIR` names the repo, so the global copy names
  `$HOME`.
- **The `finish` part's two pointers.** The skill file is beside the block, and `## Finish`
  is always the project's own `CLAUDE.md` — which `~/.claude/CLAUDE.md` is not.

Both scopes ship the same skills, the three worktree ones included: seven when this was
written, nine since ADR-next-a-grilled-brief-is-written-down-before-it-is-built. The global
install is the only source of them on a machine that has it; see the 2026-10-04 amendment
below.

## The repo's copy wins, and the global one stands down

Claude Code loads both, so a repo carrying its own install has everything twice. One rule
settles it everywhere: **the per-repo install is in force and the global one stands down.**

- **Hooks** are the sharp case: Claude Code *merges* the hook arrays, so both would fire —
  two denials for one tool call, and two entries on the doorstep for one finished turn,
  which is the same question delivered to the person twice. The global shim therefore
  exits before it resolves anything when the repo both **has** `.claude/hooks/whiska.sh`
  and **wires** it in its own `settings.json` or `settings.local.json`. Both halves are
  required, and that is the security of it: a repo's settings file is text the repo ships,
  so checking only for the string would let any repo the person clones switch Whiska's
  containment off inside itself. A repo that has the shim and wires it is a repo that ran
  `whiska init`. It greps rather than parsing — a hook cannot assume `jq` is installed —
  and tests `-f` rather than `-r`, because `-r` is true of a FIFO and grep on one with no
  writer waits for ever, on a hook that fires on every tool call.

  One case it does not catch: a repo whose per-repo entry predates the shim (ADR-0035) names
  the binary directly and has no `whiska.sh` at all, so the global copy does not stand down
  and both hooks fire. `whiska doctor` already fails such a repo by name — "older version of
  the hook command" — with `whiska init` as the fix, and re-running it is what settles this
  too. Teaching the bash every command shape Whiska has ever written would put the fragility
  back where the first half of this check just took it out.
- **The block** is text, so the global copy carries a `scope` part saying so and a session
  follows it. Nothing can enforce this and nothing needs to: the two copies say the same
  thing, and the cost of reading both is tokens, not behaviour. It is a part rather than a
  sentence in the block's header because the header is written only when the block is
  created and never re-added to one that exists, so an uninstall that a `keep` part survived
  would leave the rule out of the block the next install writes. As a part it is replaced
  every time, and can be claimed with `keep` like any other (ADR-0045).
- **The statusline** needs no rule. A project `statusLine` replaces the global one rather
  than merging with it.
- **The skills** need no rule either. Claude Code already prefers a project skill over a
  global one of the same name (ADR-0046).

So `whiska init` never refuses, and never deletes anything. A repo whose team wants the
rules committed still commits them, on a machine that also has the global install, and a
teammate without one is unaffected. `whiska init` says the global install is there only
because it changes what the person might do next.

## The global shim skips a tool call it could never deny

The per-repo shim runs only where somebody asked for it. The global one runs on most of
every session's tool calls, in every repo on the machine — measured at ~143 ms a call,
against ADR-0033's budget of ~124 ms for the hook itself. In a repo with no mouse that
buys nothing: `PreToolUse` resolves the session's worktree first and allows outright when
there is none, so outside a `worktrees/<branch>/` folder the answer is structurally always
allow. So the global shim exits early for a `pre-tool-use` whose `CLAUDE_PROJECT_DIR` is
not inside a worktree — ~5 ms instead of ~143 ms.

Two limits make that safe. It reads `CLAUDE_PROJECT_DIR`, which is fixed for a session's
whole life, and does nothing when it is unset: the working directory follows every `cd` a
session runs and is not safe to decide on (ADR-0053). And `Stop` never takes this path at
all — a question lost is worse than a turn slowed, and `Stop` fires once a turn, where the
cost does not matter.

## The global statusline keeps the line it displaced

A `statusLine` is one value, not a list. The global install takes it over — without that
no repo gets a board at all — so the person's own global line would simply be gone. It is
written to `~/.claude/whiska-base-statusline` instead, and both scripts run it first. That
is the one new file the global install has that the per-repo one does not.

## Writes go through a symlink, never over it

`~/.claude/CLAUDE.md`, `~/.claude/settings.json` and `~/.claude/skills` are commonly
symlinks into a dotfiles repo. Replacing a link with a plain file disconnects that repo
silently: the person keeps editing dotfiles and nothing they write reaches Claude Code
again, with no error anywhere to say why.

So every write opens the path and truncates it, which follows the link and changes the
target in place. No temp file and rename, no unlink and recreate. `whiska uninstall` goes
further and leaves a symlinked file exactly where it is, naming it rather than removing
it — and `whiska init --global` prints where each change actually landed, because the
person's next move is to commit it in the repo that owns the link, not here.

## Uninstall

`whiska uninstall`, and `whiska uninstall --global`, are the mirror of `init` and the way
to hand a repo over to the global install: they take out the block, the hook entries, the
scripts and the skills, restore the displaced statusline, and touch nothing else. A file
reached through a symlink is named and left where it is — any segment of the path below
the scope's root counts, not only its last, because `~/.claude/skills` is commonly one link
into a dotfiles repo rather than a link per skill file. Where the link points does not
matter: a dotfiles repo usually lives inside the very home it is linked from, so "resolves
outside the root" would miss the common case.

One thing is not restored exactly: a displaced `statusLine` comes back as its `type` and
`command`, so any other field it carried — a `padding`, a `refreshInterval` of the person's
own — is gone. The base file holds a bare command because the scripts `cat` it and run it
without needing `jq`, and keeping a second, richer copy of the same thing beside it is a
worse trade than the field.

The house is untouched — ADR-0007 is about records, and uninstalling is about files. A part
claimed with `keep` is the person's and stays, markers and all (ADR-0045).

## Consequences

ADR-0016's reasoning is narrowed, not reversed. Per-repo is still the default and still
the only arrangement in which the rules travel to someone else's machine; `--global` is
for the repos where that is not on offer, and is explicitly the weaker choice. The table
above is now load-bearing: a new file the installer writes has to be given a home in both
scopes, or the global install is quietly missing a piece — which is why `whiska doctor`
reports the global install's four pieces separately rather than as one boolean.

The trust boundary moved with the install, and that is the part to watch. Everything
`whiska init` writes runs only where somebody asked for it; everything `--global` writes
runs in every repo the person opens, including ones they are only reading. Two of this
decision's rules exist solely because of that shift — the stand-down needs the shim as well
as the string, and `pre-tool-use` skips a call it could never deny — and neither was
necessary in the per-repo world the same code came from. A check written as a convenience
becomes a control the moment untrusted input can reach it.

`Whiska.Install` reads the filesystem now. It was pure values plus one write, and
`global_state/0` and `global_links/0` break that. The alternative was a module whose only
job is to stat eight paths, which is worse.

## Amendment (2026-10-04): the global install ships the worktree skills too

This record first kept `spawn-worktree`, `send-to-worktree` and `drop-worktree` out of the
global install:

> ADR-0046 noted that the person's dotfiles already install those three globally; a second
> global copy would be two files with one name and nothing keeping them in step.

That premise is gone. The person is taking the three out of their dotfiles, which is the
follow-up ADR-0046 named. It had already cost something: the dotfiles copy of
`spawn-worktree` sat 48 lines behind Whiska's for weeks, so every session spawned anywhere
on the machine skipped the shape step and started on the default model with nothing
recorded. Two copies drift; one source cannot.

So `whiska init --global` writes all seven skills, and the scope makes no difference to
which skills are written.

The symlink rule above is unchanged, and this is where it bites. Until the person's
dotfiles stop installing the three, `~/.claude/skills/<name>/SKILL.md` is a link into that
repo, and a global install writes Whiska's copy back through it. That is correct — the
alternative is replacing a link the person owns. `whiska init --global` prints where each of
the three actually landed, marking one reached through a symlink, so the person can see a
write into dotfiles rather than discover it later. A link left behind after its dotfiles
file was deleted is written through too, recreating the file at its target, rather than
failing the install.
