# Nothing is ever deleted — not questions, not mice, not worktrees

A single policy applied in three places, each decided separately but for the same reason:
the data is small and text-only, and keeping it doubles as a free history of every
decision made.

- **Answered questions are kept forever**, not cleaned up.
- **A mouse whose pane has died is marked dead, not deleted.** Its still-open questions
  cascade to `orphaned` rather than sitting "open" forever. It drops out of `whiska mice`
  and the statusline count, but the row stays — which is what lets `whiska reopen` update
  that same row's `pane` column and carry its whole question history along, since
  everything was always keyed by `mouse_id` and never by the pane.
- **The sweep never touches disk.** It only marks state in the database; the worktree
  folder stays exactly where it is.

## Consequences

Removing a worktree for good is only ever a deliberate, human-triggered `whiska cleanup`,
which checks the branch is actually merged and refuses without an explicit override. Even
then the mouse row itself still is not deleted — just permanently inert.
