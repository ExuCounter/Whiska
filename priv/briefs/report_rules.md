## Report

Whiska keeps your final report and links it; the person first sees only its Summary. A
`# ` title saying what is true now, then `## Summary`, then each change, then each cheap
choice, what you ran and saw, findings left unfixed, and, under `Agent usage this
session`, the lines `whiska ledger` prints, as printed. A question mid-turn has no
`## Summary`.

- Extremely concise, grammar sacrificed, yet clear to someone reading it cold. No lists,
  no tables: terse prose, a short paragraph per change. Never wrap a markdown link across
  lines.
- Summary, 3-5 lines: the outcome (after a review round, what was pushed, posted and
  resolved) and anything the person must do. It names each commit by short sha and says
  in words what it changed, why it was needed, what happens without it, and any risk;
  the last two left out when there is none.
- Each change, a few lines: the review comment in plain words, when there was one; the
  problem, with an example of why the change helps; what you decided and why; what you
  did; the change itself. A diff of about 20 lines or fewer goes inline in a `diff`
  block; a bigger one gets a line on its key part and points at the Whole diff link, or
  the Diff link after a review round. Whiska links both: paste no link.
