# Whiska ships the worktree skills, because Whiska owns the protocol

`spawn-worktree`, `send-to-worktree` and `drop-worktree` are the half of the protocol
that creates a mouse and takes it down again. Whiska is the half that tracks it, reads
its marker, and carries its question to the person. The two halves have to agree about
the worktree layout (ADR-0030), about the marker's spelling (ADR-0009), and about where
a question is read from — and they lived in different repos, with nothing enforcing the
agreement. `whiska init` now writes all three, beside `whiska-questions` and
`whiska-delivered`.

That is a widening of ADR-0022, which said "each command gets a slash-command skill".
These wrap `herdr`, not `whiska`: there is no `whiska spawn` for them to wrap, and
ADR-0021 is why — spawning happens through a conversation, and Whiska deliberately has
no command for it. The rule underneath ADR-0022 still holds, and is the reason to ship
them: a skill of fixed commands, so the model never composes the bash itself.

## Consequences

The skills are checked into this repo under `.claude/skills/` and read at compile time
by `Whiska.Install`, rather than written out inside the module the way the two reading
skills are. They are long prose, Whiska uses them on itself, and one source of truth is
the only arrangement in which the shipped copy and the committed copy cannot drift.

`herdr worktree create` picks which repo to act on from the **calling directory**, not
from `--workspace`. The skill now does `cd "$(git rev-parse --show-toplevel)"` first.
Run from a subdirectory, or from another repo's worktree, it silently made the worktree
in the wrong place — the sort of thing a skill of fixed commands exists to prevent, and
which went unnoticed for as long as it did because the calling directory usually happened
to be right.

The `worktrees/<branch>` layout note travels with the skill that creates it. `--path
worktrees/<branch>` is what `Whiska.Layout` reads a mouse's worktree root and main
checkout out of (ADR-0030), so the skill says so where somebody about to change it will
see it.

The dotfiles repo still has its own copies of these three skills and the global
`CLAUDE.md` sections they came from. Until it drops them, a machine with both has two
copies of each: the project skill wins for a repo that has been `whiska init`-ed, and the
global one applies everywhere else. Cutting them from dotfiles is the follow-up, and is
not this decision.
