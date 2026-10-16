## Report

Whiska keeps your final report and links it; the person first sees only its Summary. A
`# ` title saying what is true now, then `## Summary`, then each change, then each cheap
choice, what you ran and saw, findings left unfixed, and, under `Agent usage this
session`, the lines `whiska ledger` prints, as printed. A question mid-turn has no
`## Summary`.

- Extremely concise, grammar sacrificed, yet clear to someone reading it cold. No lists,
  no tables: terse prose, a short paragraph per change. Never wrap a markdown link across
  lines.
- Summary, read like a senior engineer's pull request description, not the whole story.
  First, what changed and why, in a line or two, always carried by a concrete
  before/after; after a review round, also what was pushed, posted and resolved. Then
  `Worth a look:`, only for where you strayed from what was agreed, a call you made
  that goes beyond the person's words, something left broken, a finding or risk left
  unfixed, or something the person must do; left out when there is none, so a routine
  build reads about three lines.
  Last, what you ran and what came back ("2461 tests pass, format clean").
- Each change, a few lines: its commit by short sha; the review comment in plain words,
  when there was one; the problem, with an example of why the change helps; what you decided and why; what you
  did; the change itself. A diff of about 20 lines or fewer goes inline in a `diff`
  block; a bigger one gets a line on its key part and points at the Whole diff link, or
  the Diff link after a review round. Whiska links both: paste no link.
