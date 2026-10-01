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

The skills are checked into this repo and read at compile time by `Whiska.Install`,
rather than written out inside the module the way the two reading skills are. They are
long prose, and one source of truth is the only arrangement in which the shipped copy and
the committed copy cannot drift. They live under `.claude/skills/` — see the addendum of
2026-10-01, which moved them to `priv/skills/`.

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

## Addendum (2026-10-01): the source is `priv/skills/`, not this repo's own `.claude/`

This ADR made the repo's own Claude Code install the source of what Whiska ships:

> The skills are checked into this repo under `.claude/skills/` and read at compile time

Those are two different jobs for one directory, and they came apart the first time this
repo was installed globally. ADR-0056 lets a repo keep its install in `~/.claude` instead
of a committed `.claude/`; doing that here deleted `.claude/skills/`, and the next
`mix test` and `mix escript.build` both died on a missing `spawn-worktree/SKILL.md`. The
repo could not build itself, and the fix the build was carrying could not be installed.

**The four long skills live in `priv/skills/<name>/SKILL.md`**, which is a build input
and nothing else. `Whiska.Install` reads them from there, and `whiska init` still writes
them to `.claude/skills/<name>/SKILL.md` under whichever scope root it is given — the
destination is untouched, in either scope. Nothing about what is installed changes.

What goes with it: a repo installed globally has no committed copy of its own, so the
drift this ADR guarded against cannot happen — `priv/skills/` is the only copy. The test
that compared the two is gone, and `test/whiska/install_worktree_skills_test.exs` asserts
the shipped bodies come from `priv/skills/` instead.
