# Shell commands are judged by a read-only allowlist, not a mutating denylist

Superseded on 2026-10-14 by
[ADR-next-a-mouse-starts-in-bypass-mode](next-a-mouse-starts-in-bypass-mode.md): Whiska reads no shell command. A
sniff mouse is denied the edit tools by name, every mouse the person's commands by plain
deny rules, and Claude Code enforces both.

The allowlist, its per-command readings of `git`, `find`, `awk` and the rest, and the
variables it judged in front of a command, are in git history.
