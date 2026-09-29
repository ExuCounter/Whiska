# Nothing is ever deleted — not questions, not mice, not worktrees

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

Removing a worktree for good is only ever a deliberate, human-triggered `whiska cleanup`,
which checks the branch is actually merged and refuses without an explicit override. Even
then the mouse row itself still is not deleted — just permanently inert.
