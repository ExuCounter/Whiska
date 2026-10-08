# Records are kept: questions and mice are never deleted

Every question and every mouse record is kept for good. The data is small and text-only,
and keeping it doubles as a free history of every decision made.

- **A question is never deleted.** Answered, closed, superseded, settled and orphaned are
  statuses on a row that stays.
- **A mouse whose pane has died is marked dead, not deleted.** Everything it left waiting,
  `sent` as well as `open`, leaves the queue: **settled** where its branch landed, since
  the merge was the answer (ADR-0064), and **orphaned** where the work never landed. The
  row stays, which is what lets a reopened pane update the same row and carry its whole
  question history, since everything is keyed by `mouse_id` and never by the pane. The
  `sent` case matters: a question left `sent` by a dead mouse held the one delivery slot
  against every later mouse's question for three hours while `whiska doctor` reported
  every check passing, so delivery releases such questions itself (ADR-0008).
- **A mouse whose worktree has been taken down is marked removed**, and its row survives,
  permanently inert.
- **Collection never touches disk.** It marks state in the database; collected doorstep
  entries are renamed `.collected`, not deleted (ADR-0036), and the worktree folder stays
  where it is.

The one thing that is taken down is a landed worktree, by the owl, together with its pane
and its branch, once the branch is merged, the worktree clean, nothing unpushed and the
mouse quiet (ADR-0061). The record of that mouse is not.
