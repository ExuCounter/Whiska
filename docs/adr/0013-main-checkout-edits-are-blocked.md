# Edits in the main checkout are blocked, including anything the main session spawns

Superseded on 2026-10-14 by
[ADR-0090](0090-a-mouse-starts-in-bypass-mode.md): a mouse starts in bypass mode with
its mode's deny list, and no rule keeps it out of the main checkout.

What it decided that still holds: setup is something the person does in the main
checkout, not something a mouse does from its worktree, and a mouse's brief says to stay
in its worktree. The rest, the carve-out for Whiska's own config files and the rule's
reach into a folder under `worktrees/` that is no worktree, is in git history.
