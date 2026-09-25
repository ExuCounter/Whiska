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
