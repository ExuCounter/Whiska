# A merged worktree is taken down by the owl, pane and all

**Supersedes the worktree half of
[ADR-0007](0007-nothing-is-ever-deleted.md)** — its "removing a worktree for good is only
ever a deliberate, human-triggered `whiska cleanup`". The rest of ADR-0007 is untouched
and still binding: answered questions are kept forever, a dead mouse is marked and never
deleted, collection still never touches disk.

## Why the old rule was narrower than it needed to be

ADR-0007 treated a worktree like the questions and the mouse records beside it: small,
cheap to keep, and carrying history worth not losing. That reading is wrong about a
worktree specifically.

A worktree is a small, one-off job. Once its branch is merged into the base branch,
everything in it is recoverable from the base branch — **the thing being removed is a
folder that can be recreated, not work that can be lost.** That is what makes
"human-triggered" narrower than it needs to be. It was not wrong; it was priced for a
loss that cannot happen once the branch has landed.

What it cost in practice: merging three branches in a day meant three rounds of checking,
pushing, dropping a worktree and deleting a branch by hand, every one of them a ritual with
a known answer.

## Decision

**The owl takes down a merged worktree by itself, in every repo, with no opt-in.** When a
mouse's branch has landed, the owl removes the worktree, closes the mouse's pane with it,
deletes the branch, and marks the mouse record removed.

### The four preconditions, which are why this is safe

All four hold, or nothing happens. They are not configurable and there is no override that
skips them.

1. **The branch is merged into the base branch.** Mechanically: the worktree's head commit
   is an ancestor of the base. This is the one that makes everything else recoverable, and
   it is a local git question — no network, no forge, no credentials.
2. **The worktree is clean.** `git status --porcelain` says nothing, untracked files
   included. An untracked file is work nobody has saved anywhere.
3. **Nothing is unpushed.** No commit on the branch is absent from every remote.
   Belt-and-braces behind the merge check, and the one that catches "merged locally into a
   base branch that itself has not been pushed".
4. **The mouse is quiet** — see below.

**Never force.** `git worktree remove` without `--force`, `git branch -d` and not `-D`,
`worktree.remove` with `force: false`. The first is a real second opinion: git refuses to
remove a worktree with anything uncommitted in it, independently of condition 2.

`-d` is a weaker guarantee than it looks, and the difference is worth writing down because
it was measured rather than assumed: **`git branch -d` deletes an unmerged branch whose
commits are on its upstream.** Git's rule is "these commits exist somewhere else", not
"this landed in the base". So `-d` protects against losing work outright and is *not* a
second opinion on condition 1 — condition 1 stands alone, and `-d` stays because there is
no reason to reach for `-D` once it has passed.

**Unknown is never permission.** A detached head, an unreadable git directory, a base
branch that cannot be resolved unambiguously, a git command that fails for any reason, a
herdr that does not answer — every one of them means *do nothing and leave it for the
person*. Nothing is logged as an error and nothing is retried in a tighter loop; the
worktree simply stays, and the person can still take it down by hand with `drop-worktree`.

### Quiet, which replaces "dead"

The obvious precondition is ADR-0026's **dead**: the pane is gone. It is rejected, because
dead means the person closed the pane, and waiting for that makes the whole feature
attended again — the manual step moves rather than disappears. **Dead is a consequence of
cleanup, not a precondition for it.**

A **quiet** mouse is one with nothing left to do and nothing anyone is waiting on:

- **Its last word was `done`.** The worktree-status marker is the only thing a turn is
  classified by (ADR-0009), and a `done` report is the mouse saying it finished. A mouse
  whose latest question is a decision, or an unmarked stop, has not said that.
- **None of its questions is `open` or `sent`.** Nothing of its is waiting on the person
  (ADR-0008). A pane torn down under a question the person has not answered destroys the
  only context the answer would have gone back to.
- **Its doorstep is empty of it.** A turn it has ended that the owl has not read yet is a
  question that does not exist yet, and tearing down on the strength of an older `done`
  would race it (ADR-0036).
- **herdr does not say its pane is working.** `idle` and `done` both mean ready for input
  and both pass; `working` and `blocked` do not; `unknown` is herdr unable to classify the
  pane, so it does not either. **No pane at all passes** — that is ADR-0026's dead mouse,
  which was the old precondition and is still a perfectly good state to clean up from.

This is deliberately strict on one case: a branch the person merged themselves, for a mouse
that never said `done`, is never cleaned up automatically. That is the conservative side of
"unknown is never permission", and `drop-worktree` still exists for it.

ADR-0026's **stuck** mouse is untouched. A stuck mouse is alive and its pane says `working`,
so it fails the fourth condition without anything here having to know what stuck means.

### The pane goes with the worktree

Removing the git worktree and leaving herdr's workspace open leaves half a thing, which is
why the `drop-worktree` skill has always done both (ADR-0046). The owl does what that skill
does: one `worktree.remove` on herdr's socket with the workspace id, `force: false`, which
removes the worktree and closes the workspace together. A worktree with no open workspace —
the mouse was already dead — is removed with plain `git worktree remove`.

**This gives the owl a power it has never had: it can make a Claude Code session
disappear.** Until now the owl could type into a pane and nothing else; ADR-0044 even took
away typing into panes that are not its own house's main session. Closing a pane is a
larger power than typing into one, and it is worth saying plainly what it means:

- A session the person was reading is gone from their screen, with its scrollback, and
  Claude Code's transcript for it is the only thing left.
- The four preconditions are the whole of the protection. There is no confirmation step and
  no undo.
- It is bounded to panes Whiska itself knows as mice of its own house, each identified by
  its marker file (ADR-0002) and matched to a worktree this repo owns. The owl closes
  nothing it did not spawn the mouse for, and never the main session.
- Accepted on the grounds that a quiet mouse on a merged branch has, by construction,
  nothing left to say.

### It applies to the work repo too

No opt-in and no per-repo switch, which means this runs in repos where a worktree can live
far longer than one afternoon and carry far more context. The preconditions are what make
that acceptable: a long-lived worktree is one that is being worked in, and a worktree being
worked in is not quiet, not clean, or not merged. Longevity is not a reason to keep a folder
whose branch has landed and whose session has nothing left to do.

## Consequences

- **The mouse record gains `removed_at`**, and ADR-0007's "the row is never deleted" still
  holds — a removed mouse is permanently inert, not gone. It is already dead by then, so
  nothing on the board or in `whiska mice` changes.
- **Cleanup rides the house's existing 60 s backstop.** It is local git and one herdr call
  for a handful of dead branches; it needs no timer of its own and no event.
- **`whiska cleanup` as a command is not built.** ADR-0007 named it, the spec lists it, and
  it was always the human trigger this ADR removes. If it comes back it is a *now, not in a
  minute* convenience, not the only way in.
- **`drop-worktree` stays exactly as it is.** It is the path for everything the
  preconditions refuse, and the person's own way to take down a worktree early.
- **This is the first thing in Whiska that deletes anything.** ADR-0007's title is no longer
  true as written, which is why it is superseded here rather than quietly amended.
- **Nothing here touches a forge.** Merged is answered by local git. The networked half of
  following a branch after its last message is ADR-0057, which is proposed, separate, and
  chains onto this one rather than being part of it.

## Considered options

**Opt in per repo, default off.** Rejected by the person whose repos they are: the
preconditions make it safe everywhere, and a switch would mostly serve to make the feature
not happen in the repo it was asked for.

**Ask first — the owl notices and delivers "this landed, drop it?" as a question.** This is
ADR-0007's rule with better ergonomics, and it keeps a decision the person makes the same
way every time. Rejected for exactly that: a question with one sensible answer is a
notification with extra steps.

**Keep the pane and remove only the worktree.** Rejected: it is the half-teardown
`drop-worktree` exists to prevent, and it would leave a Claude Code session sitting in a
folder that no longer exists.

**Archive instead of delete** — move the worktree aside rather than removing it. Rejected:
it is a folder recreatable from a merged branch, so the archive would never be read, and
ADR-0007's own reasoning (small, text-only, cheap to keep) does not apply to a checkout.
