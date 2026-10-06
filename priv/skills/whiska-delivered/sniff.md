# A sniff mouse finished with a proposal

Two signs together: the heading `whiska show <id>` printed names the branch
with `(sniff)` after it — a mouse that could only look, so its branch has
nothing to merge — and the message carries a **Proposed build** block with
Found, Build and Touches lines. Then offer one AskUserQuestion holding these
three options, in this order:

- **Build what it proposes** — its preview is the block's Found, Build and
  Touches lines, verbatim, so the person decides on the proposal itself
  rather than on a label. Its description: a fresh session builds it,
  shaped for the build.
- **Chat further** — do nothing at all. The person talks to that branch's
  session themselves.
- **Drop it** — throw the work away without merging. In prose, confirm only
  when `git log <base>..<branch>` lists commits of its own. Nothing else is
  lost, and a confirmation about nothing is one the person learns to stop
  reading.

No "(Recommended)" on any of them, whatever `## Finish` names: the one thing
asked is whether the proposal is right, and only the person's read of it can
say. `drop-worktree` removes a worktree and its workspace together.

On **Build what it proposes**, follow the `spawn-worktree` skill's section
"Building what an investigation proposed" with this question's id. Nothing
else is asked — not the branch name, the model or the effort: that section
derives each and shows them in one line.

No proposal, or a heading without `(sniff)` → read `finished.md` beside this
file instead: the four options.
