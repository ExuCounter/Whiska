# Each command gets a slash-command skill, not model-composed bash

Most Whiska commands are meant to be used by your main Claude session on your behalf —
`questions`, `reply`, `diff`, `mice`, `quiet`, `loud`, `reopen`, `cleanup` — all natural to
ask for in plain conversation. Relying on the model to translate plain English into the
right Bash call every time is exactly the failure mode the worktree-relay fix already
taught us to avoid: less surface for the model to get wrong or forget.

So `whiska init` also installs a matching Claude Code skill per command in
`.claude/skills/` — real slash commands (`/whiska-questions`, `/whiska-reply`, ...),
discoverable via `/help`. Each skill is a thin wrapper that runs the fixed `whiska`
command and nothing more.

## Consequences

Which commands belong to whom is drawn by one fact: `whiska start` *creates* the Claude
session, so it cannot be something Claude runs for you. That splits the surface three ways
— typed by you before a session exists (`init`, `start`, `stop`, `doctor`, `update`), used
by your session once one is running (the list above), and machine-wide with no "right repo"
to run them in (`projects`, `goto`).
