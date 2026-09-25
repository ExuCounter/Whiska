# Whiska

An Elixir/OTP coordinator that manages Claude Code worker sessions running in isolated
git worktrees, replacing this repo's bash-based worktree-notification relay.

## Language

**Whiska**:
The per-project coordinating presence a person controls directly — their main Claude
Code session for a project, backed by that project's own house in the shared owl.
_Avoid_: instance, coordinator

**Mouse**:
A running herdr pane + Claude Code session working inside its own isolated git
worktree, spawned and supervised by a Whiska.
_Avoid_: worker, crewmate, agent

**Mouse record**:
Whiska's own persisted row tracking a mouse — its pane, worktree path, branch label,
and mode — keyed by `mouse_id`. Outlives the mouse itself: a dead mouse still has a
mouse record, marked dead rather than deleted.
_Avoid_: Mouse (bare) when the distinction between the live session and the tracking
row actually matters

**mouse_id**:
The one stable identity for a mouse — an opaque id minted once and written to a hidden
marker file at the worktree's root when the mouse is created. Never the branch name or
folder path; both of those can change without the mouse_id changing.

**Question**:
A message a mouse sends when it finishes a turn. Most are real questions — they enter
the delivery queue and wait for an answer. The one exception is a `done` report: it's
closed on arrival, never delivered, never answered — a question in name and storage
only, not in behavior.
_Avoid_: report, event (as the table/record name)

**Build mode**:
A mouse mode that produces a real code change. Edits confined to its own worktree,
push needs approval.

**Sniff mode**:
A mouse mode for investigation only. Never writes code, never pushes — produces a
report instead.

**Owl**:
The one always-awake presence per machine, supervised by `launchd`, that keeps every
project's house standing and is the only thing that can see across all of them at
once. Not per-project: a person has many houses and exactly one owl.
_Avoid_: daemon, server, service

**House**:
One project's permanent home — its own database, its own mouse records, its own
identity — isolated from every other project's. A house exists from the first
`whiska start` in a repo onwards; it is never destroyed by stopping.
_Avoid_: subtree (means a git subtree and an OTP supervision subtree — both wrong
here), slice, partition

**Open house / shut house**:
Whether the owl is currently keeping a house's lights on. `whiska start` opens a house
— its socket starts listening, its sweep timer runs, it gets its own supervision inside
the owl. `whiska stop` shuts it: socket closed, sweep stopped, supervision dropped. The
house itself, its database and its mouse records, is untouched either way.
_Avoid_: creating/destroying, starting/tearing down a house (those describe the house,
not its lights)
