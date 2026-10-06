# A finished line: what to do with the branch

Offer what to do with the branch, with one AskUserQuestion holding these
four options in this order:

- **Land here (Recommended)** — cherry-pick the branch's own commits onto
  the current branch, oldest first, skipping its merges from the base
  (`git log --no-merges --reverse <base>..<branch>` lists them); run this
  repo's tests, and only if they pass, drop the worktree and delete the
  branch.
- **Open a merge request / PR** — push the branch and open it with `gh`
  or `glab`, whichever this repo's host wants. The body is the message you
  just showed: the branch's own session wrote it, with context you lack, so
  carry it over rather than composing a summary from the diff. Neither
  tool installed or signed in → say plainly what is missing and stop,
  improvising no substitute.
- **Chat further** — do nothing at all. The person talks to that branch's
  session themselves.
- **Drop it** — throw the work away without merging. Ask them to confirm
  in prose first, in one line naming what is lost: it discards every
  commit on the branch.

Each option runs what already exists: `drop-worktree` removes a worktree
and its workspace together, and this repo's test and push commands are
whatever its own instructions say.

This repo's `CLAUDE.md` names the usual choice — a line like
`finish: land here` under a `## Finish` heading → that one carries
"(Recommended)" instead, and goes first. Same four options, same order. No
such line → "Land here" is the recommended one.
