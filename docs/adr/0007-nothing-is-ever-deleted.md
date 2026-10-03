# Nothing is ever deleted — not questions, not mice, not worktrees

**The worktree half is superseded on 2026-10-02 by
[ADR-0061](0061-a-merged-worktree-is-taken-down-by-the-owl.md)**: the owl takes a merged
worktree down by itself, pane and all, with no human trigger. The title is no longer true
as written. Everything else below still holds — answered questions are kept forever, a dead
mouse is marked rather than deleted, collection still never touches disk, and a removed
mouse's row survives as a permanently inert record.

A single policy applied in three places, each decided separately but for the same reason:
the data is small and text-only, and keeping it doubles as a free history of every
decision made.

- **Answered questions are kept forever**, not cleaned up.
- **A mouse whose pane has died is marked dead, not deleted.** Everything it left waiting
  cascades to `orphaned` rather than sitting there forever — sent as well as open. It drops
  out of `whiska mice` and the statusline count, but the row stays — which is what lets
  `whiska reopen` update that same row's `pane` column and carry its whole question history
  along, since everything was always keyed by `mouse_id` and never by the pane.

  *The sent one, added 2026-09-29.* This once cascaded only `open` questions. Delivery is
  a queue with one slot (ADR-0008) and no answer can reach a dead mouse, so a question
  left `sent` held that slot against every later mouse's question — for three hours in
  one house, while `whiska doctor` reported every check passing. The owl frees the slot
  by itself now, at house open and on the backstop, and the doctor names the dead mouse
  that is holding it instead of passing.
- **Collection never touches disk.** It only marks state in the database; the worktree
  folder stays exactly where it is.

## Consequences

~~Removing a worktree for good is only ever a deliberate, human-triggered `whiska cleanup`,
which checks the branch is actually merged and refuses without an explicit override.~~
Superseded by ADR-0061: the owl does it, unattended, once the branch is merged, the
worktree is clean, nothing is unpushed and the mouse is quiet. The mouse row itself still
is not deleted — just permanently inert.
