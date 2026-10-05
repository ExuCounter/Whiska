---
name: send-to-worktree
description: "Route a follow-up idea into the Claude session already building its branch in a worktree, without blocking or switching the person's view. Use when the person gives a new idea, refinement, or sub-task for a branch a worktree is already building, rather than a separate piece of work."
---

# send-to-worktree

Send a follow-up into a mouse already running on its branch. A separate piece of work —
one that ships on its own — is `spawn-worktree`'s job instead.

## 1. Preconditions

```bash
test "${HERDR_ENV:-}" = 1
command -v herdr
command -v whiska
```

Any check fails → say what is missing and stop.

## 2. Route here, or spawn?

git allows one worktree per branch, so the question is whether the idea belongs on a
branch that already has one:

- **Same branch and PR** — a refinement, sub-part or follow-up of the feature being built
  there → route it here.
- **Separate** — an unrelated bug, a second feature that could ship on its own, work that
  would conflict if done in parallel → `spawn-worktree`.

Not obvious from the idea → ask the person one direct question naming the candidate
worktree and branch.

## 3. Find the pane

```bash
whiska worktrees
```

One line per worktree, tab-separated: branch, path, herdr workspace id, pane id, pane
status; `-` means none. Match by branch name, or by what is being built there.

- More than one plausible match → ask which.
- No match → this is a spawn, not a route: say so and suggest `spawn-worktree`.
- Pane is `-` → no session runs there, so there is nothing to send to: say so.

The status says when the idea is read: `working` queues it behind the current task, and
the report says so rather than implying it is picked up at once; `idle` or `blocked`
reads it right away.

## 4. Send it and return

```bash
herdr agent prompt <pane-id> "<the idea, in the person's own words>"
```

The call must return immediately, so leave `--wait` off: the person's own terminal never
blocks on the mouse's work. Send the idea as the person phrased it, with every detail the
mouse will need.

## 5. Report

One line: which worktree and branch got the idea, and whether that session was busy (it
picks the idea up after) or free to start now. Say it will not interrupt the person, and
that Whiska delivers its question when it has one. Then stop: the idea is the mouse's to
investigate now.

Its questions reach the main session through Whiska once this repo is `whiska init`-ed and
the owl is running (`whiska doctor` checks both): every turn there ends with a status
marker, the owl delivers a one-line pointer, and `whiska questions <id>` shows the whole
message. Read it there, never from the pane: Claude Code runs on the alternate screen, so
`herdr pane read` returns a truncated tail.
