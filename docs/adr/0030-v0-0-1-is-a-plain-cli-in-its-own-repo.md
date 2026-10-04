# v0.0.1 is a plain CLI in its own repo, not the owl

The first real slice is the smallest end-to-end piece that proves the core plumbing —
identity, storage, one enforced rule. It is a plain CLI (`mix escript.build`), not a
long-running process: the `PreToolUse` hook invokes it fresh on every tool call, it opens
the SQLite file, makes its one decision, and exits. No supervision tree yet.

Two defaults were deliberately reversed to get here:

- **New repo now, not later.** The design originally said Whiska stays staged in dotfiles
  until code-writing starts. That point arrived, so `whiska` is its own repo, gitignoring a
  `worktrees/` folder the same way dotfiles does. The spec stays behind in dotfiles as the
  design record rather than being copied over.
- **CLI, not owl.** The full design is one supervised process per machine (ADR-0001), but
  that is explicitly not part of this slice.

The escript stays Elixir for this slice only. Its ~171 ms cold start is paid on every tool
call, which is survivable while testing and not while living in — see ADR-0033, which moves
the hook client to a native binary at the point the owl takes over its database and
id-minting work.

## Consequences

Storage uses real `Ecto.Migration` + SQLite from day one — the same technology the owl will
use, just opened per invocation — and both tables carry their real schema immediately, so
nothing about them changes shape when the owl arrives. `Mouse.mode` is stored but not read
by any v0.1 logic.

`mouse_id` is minted lazily, on the first hook invocation inside a worktree with no marker
file, and the CLI writes the marker file itself. Nothing upstream (`spawn-worktree`) has to
change for this slice.

The one enforced rule is: deny any tool call whose target path resolves to the main checkout
rather than the current worktree. Detected by comparing against the known main-checkout
path, not git internals (`git worktree list`, `.git` file-vs-directory checks), since Whiska
already knows that path from how `spawn-worktree` lays worktrees out under
`worktrees/<branch>/`.

Deferred on purpose, not forgotten: sniff-mode read-only enforcement uses this exact same
hook and decision point, so it is trivial to add once this lands. Leaving it out keeps the
first pass to the simplest possible rule instead of also getting mode-awareness right on day
one. Also out of scope: the owl and its supervision tree, cross-repo commands, `checks.yml`,
push approval, and the herdr/Mox boundary — v0.0.1 does not talk to herdr at all.

## Note, 2026-09-29: one `.git` check, for slashed branch names

A branch name may carry a slash, and git nests it on disk: `feat/csv-data-page` is laid
out at `worktrees/feat/csv-data-page`, with `worktrees/feat` an ordinary directory that
owns nothing. Reading the folder directly under `worktrees/` as the worktree made every
such mouse a mouse called `feat`, sharing one marker file and one worktree root with
every other branch under `feat/` — so `whiska mice`, the delivered line and the board all
named the wrong thing, and the main-checkout rule let a mouse write into its siblings.

Nothing about the shape of the tree says where a nested branch name ends, so `Layout`
now reads one piece of git state: the `.git` file git writes into every linked worktree.
The worktree root is the deepest directory between `worktrees/` and the working
directory that has one, and the branch label is that root's path relative to
`worktrees/`.

*Rewritten 2026-10-02.* This once kept a fallback: with no such file anywhere, the root
was still the folder directly under `worktrees/`. That fallback minted a phantom. An
invocation sitting in `worktrees/quality` — the folder `quality/QUAL-350-lnkd-emails`
nests under — was read as a mouse called `quality`, with a marker file of its own and a
record of its own, and in one work repo a question from that phantom took the one
delivery slot and wedged every later question behind it (ADR-0057). **So there is no
fallback: a folder under the container that is no checkout of its own is no worktree.**
git answers that question directly, and the answer does not change as the folder's
children come and go — an inference from the neighbours would have minted the phantom
again the day both branches under it were dropped.

What that costs: a worktree laid out by hand or by another tool, with no `.git` file in
it, is nobody — no mouse record, no mode, no marker. **Identity goes; containment does
not.** A session whose start directory is such a folder is still denied a write into the
main checkout (ADR-0013), through `Layout.unplaced/1`, which reads the folder for that
rule alone and carries no branch. A folder Whiska cannot identify is the one it can
vouch for least, so the one path that bypasses every other guard fails closed there.

This narrows the rule above: no `git worktree list`, and the main checkout is still
found by path arithmetic rather than by probing. One `File.stat` per level is all git is
asked for, and it is asked only to decide where a branch name stops.


## Note, 2026-10-03: minting is no longer only lazy

ADR-0069 has `spawn-worktree` run `whiska shape` in the new worktree before Claude starts,
which mints the marker and the record then. Lazy minting on the first hook call remains,
for a mouse nobody shaped. "Nothing upstream has to change" was this slice's scope, not a
standing rule.
