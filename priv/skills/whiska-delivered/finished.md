# A finished line: what to do with the branch

`whiska show <id>` printed a line straight under the heading, starting
`On the branch:` — Whiska's record of the branch, read from git just now.
Choose by that line, never by the mouse's account of its own work: read it
from its start, find the row it begins as, then offer that row's options
with one AskUserQuestion, in that order.

| The line says | Options, in order |
|---|---|
| `<N> commit(s) beyond <base> · nothing uncommitted` | Land here (Recommended), Open a merge request / PR, Drop it |
| `<N> commit(s) beyond <base> · <N> file(s) not committed: …` | Commit and land (Recommended), Commit and open a PR, Drop it |
| `nothing committed beyond <base> · <N> file(s) not committed: …` | Commit and land (Recommended), Commit and open a PR, Drop it |
| `nothing committed beyond <base> · nothing uncommitted` | none: a reply, not a choice — see below |
| `On the branch: unknown — …`, or no such line | as for commits and nothing uncommitted: unknown keeps every option |

## A reply: nothing on the branch, no Proposed build

The message is the mouse's answer to something the person asked. Offer no
picker: show the message and stop. The person's next message goes to that
mouse word for word when it reads as a reply to it: a question or instruction
about what the mouse said, or a message that names it. Send it as "Text typed
into Other" below says. A message meant for the main session itself, or "hold
it", is not sent. If it could be read either way, ask one line first: "send
this to <branch>?" The mouse's answer comes back as a new finished line.

This repo's `CLAUDE.md` may name the usual choice — a line like
`finish: land here` under a `## Finish` heading. Where Land here would be
recommended, that one carries "(Recommended)" instead, and goes first.
Where Commit and land would be recommended, the commit-first form of that
choice carries it: a repo whose usual choice is a merge request recommends
Commit and open a PR.

## The options

- **Land here** — cherry-pick the branch's own commits onto the current
  branch, oldest first, skipping its merges from the base
  (`git log --no-merges --reverse <base>..<branch>` lists them); run this
  repo's tests, and only if they pass, drop the worktree and delete the
  branch.
- **Commit and land** — the main session commits the files the mouse left,
  in its worktree, then lands. Before offering it, find the worktree's path
  with `whiska worktrees` and list its changes in full with
  `git -C <worktree> status --porcelain --untracked-files=all`, not the
  branch line's first few names: the option's preview is every file that
  will be committed, so the person can spot a scratch file before it lands.
  Whiska's own `.whiska-mouse` and `.whiska-spec.md` are never committed,
  and are left out of the preview. A file that looks like a secret or local
  setup — a `.env`, a key, a `.claude/` folder `spawn-worktree` copied in —
  is marked in the preview, and no option is recommended, whatever the
  table or `finish:` says: committing it is the person's call. On the pick,
  run `git -C <worktree> add -A -- . ':!.whiska-mouse' ':!.whiska-spec.md'`,
  then list what is staged with
  `git -C <worktree> diff --cached --name-only --no-renames` and compare its
  paths with the preview's; a path in one and not the other →
  `git -C <worktree> reset`, stop and name the difference. Write the commit
  message with the file tool to a file outside both checkouts, in this
  repo's commit style, from the mouse's report, and run
  `git -C <worktree> commit -F <file>`: no path or word the mouse wrote goes
  on the command line. Git refuses — a hook, nothing to commit → stop and
  say why in its own words; nothing lands. Then exactly as Land here.
- **Open a merge request / PR** — push the branch and open it with `gh`
  or `glab`, whichever this repo's host wants. The body is the message you
  just showed: the branch's own session wrote it, with context you lack, so
  carry it over rather than composing a summary from the diff. Neither
  tool installed or signed in → say plainly what is missing and stop,
  improvising no substitute.
- **Commit and open a PR** — commit as Commit and land does, preview
  included, then exactly as Open a merge request / PR.
- **Drop it** — throw the work away. First confirm in prose, in one line
  naming what is lost: every commit on the branch, and each file not
  committed. A branch with nothing on it needs no confirmation: nothing is
  lost, and the report stays readable with `whiska show <id>`.

## Text typed into "Other"

Text the person typed into "Other" goes to the mouse, and so does a reply the
person types after a no-picker line above. Find its pane with
`whiska worktrees` and type it in their own words, in single quotes with
each `'` in it written `'\''`:

    herdr agent prompt <pane-id> '<their words>'

This is not an answer — the finished question is closed and `whiska reply`
refuses it — so it travels the way `send-to-worktree` sends a follow-up. The mouse's own
reply returns here as a finished line; the person never moves into its pane
unless they ask for `whiska open <id>`.

`drop-worktree` removes a worktree and its workspace together, and this
repo's test and push commands are whatever its own instructions say.
