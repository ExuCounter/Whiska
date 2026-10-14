# A new worktree is stocked by `whiska shape`, copy-on-write, from a list the house keeps

`whiska shape` (ADR-0069) also clones the main checkout's untracked folders into the new
worktree before Claude starts: `deps` and `_build` for a `mix.exs` project, `node_modules`
for a `package.json` one. The clone is copy-on-write, never a symlink, so each mouse owns
its copy. On macOS each folder is one `clonefile(2)` call, made by name through
`/usr/bin/osascript`'s JavaScript; when it fails, `cp -c` clones that entry instead. On
Linux it is `cp --reflink=auto`. The marker folders are cloned
only when the worktree's lockfile equals the main checkout's. A failed clone never fails
the shape: it becomes the one stderr line the spawn reports.

## The per-repo list

`<main-checkout>/.git/whiska/clone`, in the house beside the doorstep and the backstop, in
the plain-text form of ADR-0039: one path per line relative to the repo root, `#` for a
comment, a lone `off` to turn cloning off. Listed paths are added to the defaults and
cloned without the lockfile check. It is not in the repo's tree, and not at
`~/.whiska/houses/<repo>`: that path is the open-houses record, a file.

A listed folder the worktree already holds is merged, never overwritten: only its missing
entries are cloned.

## Hidden from git

Each entry cloned goes into the main checkout's `.git/info/exclude` (one file, read by
every worktree), unless git already ignores it. Without it a copy is an untracked change:
`whiska land` refuses it as a file not committed, and the owl will not take the worktree
down (ADR-0061). The line names the entry cloned (`/.claude/skills/duty`), not the whole listed
folder, so a file a mouse really adds beside it still shows. Lines are never removed.

## Alternatives not taken

- A separate `whiska clone` command: one more step to forget, where `whiska shape`
  already runs in the worktree before Claude and cannot be skipped. Cost: the Shape term
  now covers stocking too.
- `cp -c` alone on macOS: it clones one file at a time, 7.5s for a Phoenix app's `deps` and
  `_build` against 0.3s for one `clonefile(2)` per folder. `ditto --clone`, `copyfile(3)`
  and Foundation's `copyItem` are as slow. Apple discourages `clonefile(2)` on a folder;
  it gave the same files.
- `clonefile(2)` by syscall number through Perl, or a bundled NIF: the number can change
  under us (the first one tried was wrong), and a NIF needs a C build step.
- Symlinks: one mouse's `mix deps.update` would change every other mouse's deps.
- `.venv`: a virtualenv holds absolute paths into the main checkout.
- The override in the repo: every contributor would get the person's untracked paths.
