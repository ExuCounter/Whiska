# A folder under `worktrees/` that is no checkout of its own is nobody

A worktree is found by path arithmetic plus one look at git. `Layout` walks up from the
directory a session started in until an ancestor's parent is named `worktrees`; that
ancestor's grandparent is the main checkout. A branch name may carry a slash and git
nests it on disk, `feat/csv-data-page` at `worktrees/feat/csv-data-page`, so the worktree
root is the deepest directory below `worktrees/` carrying the `.git` file git writes into
every linked worktree, and the branch label is that root's path relative to `worktrees/`.
No `git worktree list`; one `File.stat` per level, asked only to decide where a branch
name stops.

**There is no fallback.** A folder under the container with no such file is no worktree
and mints nothing: no mouse record, no mode, no marker. That covers the ordinary folder a
slashed branch nests under, and a worktree laid out by hand or by another tool.

## Why no fallback

The first version read the folder directly under `worktrees/` as the worktree, which made
every branch under `feat/` one mouse called `feat`, sharing a marker file and a root, so
the main-checkout rule let a mouse write into its siblings. The fix kept a fallback for a
folder with no `.git` file anywhere, and that minted a phantom: an invocation sitting in
`worktrees/quality`, the folder `quality/QUAL-350-lnkd-emails` nests under, became a
mouse called `quality` with a record of its own, and in one work repo a question from it
took the one delivery slot and wedged every later question behind it (ADR-0008). git
answers the question directly, and its answer does not change as the folder's children
come and go; an inference from the neighbours would have minted the phantom again the
day both branches under it were dropped.

## Consequences

**Identity goes; containment does not.** A session whose start directory is such a folder
is still denied a write into the main checkout (ADR-0013), through `Layout.unplaced/1`,
which reads the folder for that rule alone and carries no branch. A folder Whiska cannot
identify is the one it can vouch for least, so the one path that bypasses every other
guard fails closed there.

A `mouse_id` is minted by `whiska shape` when the spawn shapes the mouse (ADR-0069), and
lazily on the first hook call for a mouse nobody shaped; either way the marker is written
by Whiska, never by the model (ADR-0002).
