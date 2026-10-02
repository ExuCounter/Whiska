# Edits in the main checkout are blocked, including anything the main session spawns

Surfaced by a real firstmate incident: their primary once ran work through Claude Code's
own subagent tool instead of a real spawned worker, and that work had no durable fleet
record and bypassed every one of their guards. The same risk applies here. Every
protection in this design — worktree containment, the finish pipeline, diff review, push
approval — only covers a mouse's own worktree. An edit made directly in the main checkout
skips all of it.

## Consequences

Carved out and still directly editable: Whiska's own config files — `dispatch.yml` and
the `CLAUDE.md` block. Those are meta/setup rather than project code, and
blocking them would make basic setup painfully indirect.

**The carve-out is scoped to the main session editing its own repo's setup, and does not
extend to a mouse.** A mouse reaching out of its worktree into the main checkout is the
containment breach this decision exists to stop, and it is no less of one because the file
it reaches for happens to be `CLAUDE.md`. Setup is something a person does in the main
checkout, not something a worker does from inside a worktree. So from a worktree, every
main-checkout edit is denied, config files included — v0.0.1 implements exactly that (see
ADR-0030).

**It reaches a session that is no mouse at all, when that session sits under
`worktrees/`.** A folder there which is no checkout of its own mints no mouse (ADR-0030's
note, rewritten 2026-10-02) — and losing identity must not mean losing containment, which
would hand a session Whiska cannot account for the one permission a mouse does not have.
So the main-checkout rule is applied from such a folder too, with the folder itself
standing in for the worktree: a write below it is left alone, a write into the main
checkout is denied, and nothing is minted or recorded either way. The main session is
untouched — it is recognised by its pane (ADR-0053), and it does not start there.

This rule aims at the main session. It is the mirror image of the standing permission for
mice, which may use subagents freely inside their own worktree — that work never leaves
the worktree, so none of Whiska's rules apply to it.
