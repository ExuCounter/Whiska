---
name: drop-worktree
description: "Take a worktree down: its git worktree, herdr workspace and branch, together. Use when the person asks to drop, delete, close, remove, or clean up a worktree. Requires HERDR_ENV=1."
---

# drop-worktree

Take a worktree down early — before its branch has landed, or because the person asks
now. Both halves go together: the git worktree alone leaves a stale herdr workspace, the
workspace alone leaves the worktree on disk. A landed worktree needs none of this: the
owl removes it, closes its pane and deletes its branch once the mouse is quiet.

The mouse's record survives the drop, marked dead, and its questions stay readable.

## 1. Preconditions

```bash
test "${HERDR_ENV:-}" = 1
command -v herdr
command -v whiska
command -v git
```

Any check fails → say what is missing and stop.

## 2. Name the target

The person named one → use it. Otherwise show the list and ask which:

```bash
whiska worktrees
```

One line per worktree, tab-separated: branch, path, herdr workspace id, pane id, pane
status; `-` means none. A name that matches more than one → ask which. Done when exactly
one worktree is named by the person.

## 3. Look for uncommitted work

```bash
git -C <worktree-path> status --porcelain
```

Empty → go on. Otherwise say what is dirty and go on only on an explicit "yes, drop it
anyway"; work is discarded only with that yes.

## 4. Remove both halves

```bash
herdr worktree remove --workspace <workspace-id>
```

Add `--force` when step 3 found dirty work and the person confirmed. Then check both are
gone:

```bash
git worktree list                                  # the target path should be gone
herdr workspace list | grep '"<workspace-id>"'     # no output: the workspace is closed
```

Either still there → finish it by hand:

- git worktree: `git worktree remove <path> --force`
- herdr workspace: `herdr workspace close <workspace-id>`

## 5. Delete the branch

Removing a worktree leaves its branch. Delete it by default: `spawn-worktree` made most of
these fresh, and they are throwaway once the worktree goes. First look for work on no
remote:

```bash
git log --oneline <branch-name> --not --remotes
```

Commits listed → warn the person and ask before deleting. None → delete without asking:

```bash
git branch -D <branch-name>
```

Keep the branch only when the person says to.

## 6. Report

One line: what was removed, and whether the branch was kept.
