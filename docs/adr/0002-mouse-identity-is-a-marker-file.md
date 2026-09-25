# Mouse identity is an opaque marker file, not the branch name or folder path

A mouse needs one stable key, and neither of the obvious candidates is stable: branches
get renamed casually, worktree folders get moved, and someone can in principle check out
a different branch inside an existing worktree folder. Keying on either would silently
break tracking. Instead, at worktree creation Whiska drops a small hidden file at the
worktree root holding one opaque, Whiska-minted `mouse_id` — the same pattern this repo
already proves with `.herdr-worktree-meta` for pane tracking.

## Consequences

The file is written once, by a script, never by the model; hooks only read it, which is
no more complex than reading a branch name and involves no parsing. It is gitignored,
like the existing meta file. Branch and path become mutable labels on a mouse record
rather than its identity, so renaming or moving a worktree is a no-op for tracking.
