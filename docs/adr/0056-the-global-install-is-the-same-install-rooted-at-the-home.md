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

Three differences, each forced:

- **The hook command.** `$CLAUDE_PROJECT_DIR` names the repo, so the global copy names
  `$HOME`.
- **The `finish` part's two pointers.** The skill file is beside the block, and `## Finish`
  is always the project's own `CLAUDE.md` — which `~/.claude/CLAUDE.md` is not.
- **The worktree skills.** `spawn-worktree`, `send-to-worktree` and `drop-worktree` are not
  in the global install. ADR-0046 noted that the person's dotfiles already install those
  three globally; a second global copy would be two files with one name and nothing keeping
  them in step. The four that read and finish — `whiska-questions`, `whiska-delivered`,
  `whiska-reply`, `whiska-finish` — are shipped, because nothing else ships them at all.

## The repo's copy wins, and the global one stands down

Claude Code loads both, so a repo carrying its own install has everything twice. One rule
settles it everywhere: **the per-repo install is in force and the global one stands down.**

- **Hooks** are the sharp case: Claude Code *merges* the hook arrays, so both would fire —
  two denials for one tool call, and two entries on the doorstep for one finished turn,
  which is the same question delivered to the person twice. The global shim therefore
  exits before it resolves anything when the repo's own `settings.json` (or
  `settings.local.json`) wires Whiska. It greps for the shim path rather than parsing:
  a hook cannot assume `jq` is installed.
- **The block** is text, so the global copy says so in its header and a session follows it.
  Nothing can enforce this and nothing needs to: the two copies say the same thing, and the
  cost of reading both is tokens, not behaviour.
- **The statusline** needs no rule. A project `statusLine` replaces the global one rather
  than merging with it.
- **The skills** need no rule either. Claude Code already prefers a project skill over a
  global one of the same name (ADR-0046).

So `whiska init` never refuses, and never deletes anything. A repo whose team wants the
rules committed still commits them, on a machine that also has the global install, and a
teammate without one is unaffected. `whiska init` says the global install is there only
because it changes what the person might do next.

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
scripts and the skills, restore the displaced statusline, and touch nothing else. The
house is untouched — ADR-0007 is about records, and uninstalling is about files. A part
claimed with `keep` is the person's and stays, markers and all (ADR-0045).

## Consequences

ADR-0016's reasoning is narrowed, not reversed. Per-repo is still the default and still
the only arrangement in which the rules travel to someone else's machine; `--global` is
for the repos where that is not on offer, and is explicitly the weaker choice. The table
above is now load-bearing: a new file the installer writes has to be given a home in both
scopes, or the global install is quietly missing a piece — which is why `whiska doctor`
reports the global install's four pieces separately rather than as one boolean.

`Whiska.Install` reads the filesystem now. It was pure values plus one write, and
`global_state/0` and `global_links/0` break that. The alternative was a module whose only
job is to stat eight paths, which is worse.
