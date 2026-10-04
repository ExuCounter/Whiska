# Mouse modes are build and sniff

A mouse carries a mode flag; it is the same kind of mouse either way. **build** produces a
real change — edits confined to its own worktree, push needs approval. There is no
default: the spawn chooses a mode before Claude starts, and a mouse nobody chose for may
read but not write (*rewritten 2026-10-03*, ADR-0069 — build used to be the default).
**sniff** is investigation only: it writes a report, never a PR, and `PreToolUse` blocks
*all* edits, not just ones outside the worktree, because a sniff mouse should never write
code at all.

The concept is borrowed from firstmate's Ship/Scout, but the names are not. Renaming was an
explicit instruction: no firstmate vocabulary should leak into this project's language.

## Consequences

Sniff-mode enforcement uses the same hook and the same decision point as the worktree rule,
so it is trivial to add — it is deliberately deferred out of v0.0.1 (see ADR-0030) rather
than being hard.


## Note, 2026-10-03: reachable at last

Until ADR-0069 nothing set the mode, so every mouse ran as build. A spawn now shapes a
mouse — mode and model — before Claude starts. Build stopped being the default at the
same time: a skipped spawn step left a mouse asked for as sniff with write access, and
nothing said so. A mouse nobody shaped is now held to sniff's rules, with a reason that
sends it to the person, until they run `whiska mode build` or `whiska mode sniff`. Mice
already recorded when this landed were stamped as shaped, so none was stopped mid-task.

## Note, 2026-10-04: a flip carries its shape along, and says so

A mode moved by `whiska mode` after the spawn keeps the model and effort the mouse was
started on, chosen for the other mode's work. The flip still works, and now says what it
carried; a finished investigation is built by a fresh mouse instead, shaped for the build
(ADR-next-a-finished-investigation-hands-off). A sniff mouse denied an edit is told to
end on a proposal, no longer to ask for `whiska mode build`.
