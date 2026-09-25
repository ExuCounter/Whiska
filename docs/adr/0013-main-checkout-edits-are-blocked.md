# Edits in the main checkout are blocked, including anything the main session spawns

Surfaced by a real firstmate incident: their primary once ran work through Claude Code's
own subagent tool instead of a real spawned worker, and that work had no durable fleet
record and bypassed every one of their guards. The same risk applies here. Every
protection in this design — worktree containment, `checks.yml`, diff review, push
approval — only covers a mouse's own worktree. An edit made directly in the main checkout
skips all of it.

## Consequences

Carved out and still directly editable: Whiska's own config files — `checks.yml`,
`dispatch.yml`, the `CLAUDE.md` block. Those are meta/setup rather than project code, and
blocking them would make basic setup painfully indirect.

**The carve-out is scoped to the main session editing its own repo's setup, and does not
extend to a mouse.** A mouse reaching out of its worktree into the main checkout is the
containment breach this decision exists to stop, and it is no less of one because the file
it reaches for happens to be `CLAUDE.md`. Setup is something a person does in the main
checkout, not something a worker does from inside a worktree. So from a worktree, every
main-checkout edit is denied, config files included — v0.0.1 implements exactly that (see
ADR-0030).

This rule aims at the main session. It is the mirror image of the standing permission for
mice, which may use subagents freely inside their own worktree — that work never leaves
the worktree, so none of Whiska's rules apply to it.
