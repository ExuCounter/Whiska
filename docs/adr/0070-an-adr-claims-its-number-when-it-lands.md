# An ADR claims its number when it lands

This repo's ADR numbers collided five times on 2026-10-03. Two branches cut from the same
main each scanned `docs/adr/` for the highest number and took the next one, and whichever
merged second renumbered its file, its README entry and its citations through `lib/` and
`test/` by hand (f399c37, 7cc2aa8 and a0a963c are three of them). A branch has to pick
its number when it is cut, but the number can only honestly be known when it lands.

## Decision

**A new record is written under a placeholder, and the number is handed out just before
the branch merges.**

- The file is `docs/adr/next-<slug>.md`. It is cited as `ADR-` followed by `next-<slug>`,
  and linked from the README as `[next-<slug>](next-<slug>.md)`.
- `mix adr.claim`, run on the branch right before the person merges it, gives each
  placeholder the next number free on both the branch and main. It rewrites the file name,
  the link and every citation in one go, so the file name and the citation key stay one
  string. The person merges locally from the picker, so the claim belongs there; nothing
  of the owl's touches it.
- `mix test` carries the check (`Whiska.Adr.problems/2`). It fails on two files with one
  number, on a citation or README link with no file behind it, and on a placeholder that
  reached main.
- Numbers stay sequential. The 68 records before this one keep theirs.

## A placeholder in flight is told from one that landed by asking main

The check must fail when a placeholder reaches main, and must not fail on a branch that
is still building, or every branch's own test run goes red and people learn to ignore
it. **A `next-` file is fine while main's tree does not hold it, and a problem once it
does.** On main, every placeholder is in main's tree. On a branch, only placeholders
leaked from main are, and those fail on every branch that pulls them in, which is right.

The collision check reads git the same way. It compares the branch's numbers with the
ones main added since the merge base. That catches a branch that took a number main has
since taken, before the merge rather than after. It also keeps a branch that renames an
existing record from looking like a collision.

## Scope

**This repo only.** Nothing goes into the installed CLAUDE.md block or the shipped skills.
A rule for other repos would have to work without `mix`, in repos that are not Elixir,
which is a different and larger job. The six ADR citations under `priv/skills/` stay
exactly as they are. That is because of this scope, not because of the scheme.

## Alternatives rejected

- **No number, the slug is the key.** Nothing can collide, but every citation gets long
  and the numbers people already know stop being the way records are named.
- **The owl claims after the merge.** Main would hold placeholders for a while, and it
  breaks ADR-0060: watching a branch only ever reads.
- **A convention in CLAUDE.md alone.** All five collisions were a convention followed
  correctly by two branches at once. The check works even on a day someone forgets the
  task.
