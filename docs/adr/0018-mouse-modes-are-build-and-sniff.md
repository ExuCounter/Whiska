# Mouse modes are build and sniff

A mouse carries a mode flag; it is the same kind of mouse either way. **build** produces a
real change and is the default — edits confined to its own worktree, push needs approval.
**sniff** is investigation only: it writes a report, never a PR, and `PreToolUse` blocks
*all* edits, not just ones outside the worktree, because a sniff mouse should never write
code at all.

The concept is borrowed from firstmate's Ship/Scout, but the names are not. Renaming was an
explicit instruction: no firstmate vocabulary should leak into this project's language.

## Consequences

Sniff-mode enforcement uses the same hook and the same decision point as the worktree rule,
so it is trivial to add — it is deliberately deferred out of v0.0.1 (see ADR-0030) rather
than being hard.
