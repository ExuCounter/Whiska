# Mice stay herdr panes; Whiska never owns Claude Code directly

Whiska could run Claude Code processes itself instead of going through herdr. Rejected:
mice should stay visible in herdr's panes and tabs, where they can be looked at, attached
to, and read like any other terminal work.

## Consequences

herdr is unchanged by this project — it creates panes, starts Claude Code, tracks status,
exactly as it does today. A mouse is not a new thing to build; it is a name for a herdr
pane running Claude Code. To answer a mouse, Whiska looks up its pane and asks herdr to
type there. The main session works the same way — it is just the pane `whiska start` was
run from.

This is also why the herdr boundary is the one place mocking is allowed (see ADR-0031).
