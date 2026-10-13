# Each command gets a slash-command skill, not model-composed bash

Superseded on 2026-10-13 by
[ADR-0088](0088-one-brief-per-session.md): procedures are commands
with fixed steps — `whiska spawn`, `send`, `land`, `pr`, `drop` — and no skill wraps any
command.

What it decided that still holds is carried there: the model never composes a procedure
out of what it read, and an answer goes through `whiska reply` and nothing else. Its
refusal of a `whiska spawn` did not survive: the judgment a spawn needs — mode, model and
effort, branch — is made in the conversation and passed as arguments, and the command
makes no choice of its own. The lettered options after a report went with the skills;
the main session shows the report and the person says what happens next. The rest — the
`whiska-delivered` skill, `finish:` under `## Finish`, why the options were plain lines and
not a picker — is in git history.

Folded in on 2026-10-08: 0021 (its text is in git history).
