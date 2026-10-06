# A finished line: what to do with the branch

`whiska show <id>` printed a line straight under the heading, starting
`On the branch:` — Whiska's record of the branch, read from git just now.
Choose by that line, never by the mouse's account of its own work: read it
from its start, find the row it begins as, then offer that row's options
with one AskUserQuestion, in that order.

| The line says | Options, in order |
|---|---|
| `<N> commit(s) beyond <base> · nothing uncommitted` | Land here (Recommended), Open a merge request / PR, Chat further, Drop it |
| `<N> commit(s) beyond <base> · <N> file(s) not committed: …` | the same four, none recommended |
| `nothing committed beyond <base> · <N> file(s) not committed: …` | The next step (Recommended), Chat further, Drop it |
| `nothing committed beyond <base> · nothing uncommitted` | Chat further, Drop it, none recommended |
| `On the branch: unknown — …`, or no such line | as for commits and nothing uncommitted: unknown keeps every option |

This repo's `CLAUDE.md` may name the usual choice — a line like
`finish: land here` under a `## Finish` heading. Where Land here would be
recommended, that one carries "(Recommended)" instead, and goes first.

## The options

- **Land here** — cherry-pick the branch's own commits onto the current
  branch, oldest first, skipping its merges from the base
  (`git log --no-merges --reverse <base>..<branch>` lists them); run this
  repo's tests, and only if they pass, drop the worktree and delete the
  branch. With files not committed, its description says they stay in the
  worktree: landing takes the commits only.
- **Open a merge request / PR** — push the branch and open it with `gh`
  or `glab`, whichever this repo's host wants. The body is the message you
  just showed: the branch's own session wrote it, with context you lack, so
  carry it over rather than composing a summary from the diff. Neither
  tool installed or signed in → say plainly what is missing and stop,
  improvising no substitute.
- **The next step** — its label names what comes next, as specifically as
  the mouse's report and the branch line allow: "Make timeout_test.exs
  pass", "Apply the cutoff fix". On the pick, find the mouse's pane with
  `whiska worktrees` and type one fixed line into it:

      herdr agent prompt <pane-id> 'Carry on with your brief from where you stopped.'

  That line, never the label: nothing the mouse wrote goes on a command
  line. Text the person typed into "Other" goes instead, in their own
  words, in single quotes with each `'` in it written `'\''`. This is not an answer — the finished
  question is closed and `whiska reply` refuses it — so it travels the way
  `send-to-worktree` sends a follow-up.
- **Chat further** — run `whiska open <id>`, with the number after the `#`. It moves
  the person's screen to that branch's pane; say what it printed in one line.
- **Drop it** — throw the work away. First confirm in prose, in one line
  naming what is lost: every commit on the branch, and each file not
  committed. A branch with nothing on it needs no confirmation: nothing is
  lost, and the report stays readable with `whiska show <id>`.

`drop-worktree` removes a worktree and its workspace together, and this
repo's test and push commands are whatever its own instructions say.
