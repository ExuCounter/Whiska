# A merged worktree is taken down by the owl, pane and all

Records are kept (ADR-0007): answered questions forever, a dead mouse marked and never
deleted, collection never touching disk. The worktree is the one thing that goes, and it
goes by itself.

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

### The base is the branch the worktree was cut from

"The base" is not the repo's default branch. A main checkout can work on `staging` while
`main` is production and dozens of commits behind it; a mouse cut from staging has landed
when staging has its work, and "N commits beyond main" would count staging's own commits as
the mouse's. `whiska shape` records, in the mouse's record, the branch the main checkout is
on when it runs in the new worktree, and every question about the base — this ADR's
landed check, ADR-0064's landing stamp, the finished line's commit count, the cold
review's diff — is asked against that branch.

A mouse with no recorded base (spawned before it was kept, or from a detached main
checkout) is read against the default branch: `origin/HEAD`, else exactly one local `main`
or `master`. A recorded base that no longer resolves is unknown, never the default branch:
the worktree stays, and the finished line says its base is gone. The reflog was rejected as
the source: it keeps the commit a branch was cut at but not the branch's name, so any
answer from it is a guess among every branch that holds that commit.

### The four preconditions, which are why this is safe

All four hold, or nothing happens. They are not configurable and there is no override that
skips them.

1. **The branch is merged into the base branch.** Mechanically: the worktree's head commit
   is an ancestor of the base. This is the one that makes everything else recoverable, and
   it is a local git question — no forge, no credentials.

   **The base is read in two places**: the branch here, then its copy last fetched from
   the remote it tracks (`origin/main`), where a merge request merged on the forge shows
   before anyone pulls. Every check below is asked of each, the base here first. The owl
   refreshes that copy with a fetch of the base alone while a merge request waits
   ([ADR-0087](0087-an-opened-merge-request-is-remembered.md));
   a fetch the person ran counts the same.

   **Or its work is in the base under other commits.** Land here copies a branch's
   commits onto the base with new ids, and a forge's squash folds them into one; neither
   leaves the head an ancestor. So a head that is not one is put to a trial merge, `git
   merge-tree --write-tree <base> <head>`: when it merges cleanly to the base's own tree,
   merging would change nothing and the work is there. Only a branch with at least one
   commit the base cannot reach is asked, since a branch that never moved merges to
   nothing too. A copy whose conflict was resolved by hand usually conflicts again here
   and reads as not landed, which leaves its worktree for the person; a git older than
   2.38 cannot answer, and unknown is not permission.

   **A branch with no commit of its own is never merged, whatever its ancestry says.** A
   commit is its own ancestor, so a branch still on the commit it was cut at — a sniff
   mouse's, whose investigation has nothing to merge, or a build mouse that committed
   nothing — passes the ancestor test the moment it exists. The owl took such sniff
   worktrees down minutes after their report, under a person who may still want to talk
   to them. So the ancestor test is only half of it: the branch's tip must also differ
   from the commit it was cut at, which the branch's own reflog records. A branch
   fast-forwarded into the base still passes — it moved before it landed — which is why
   this asks about the branch's history rather than how the base reached it
   (ADR-0064's landing stamp asks the latter, and reads a fast-forward as no landing).
   A reflog that is missing or empty is unknown, and unknown is not permission. Such a
   worktree stays until the person drops it with `whiska drop`, or, for a sniff
   mouse, until its build lands (below).

   Two limits, both on the safe side. The test is "the tip moved", not "a commit of its
   own": a sniff mouse that fast-forwards its own branch (`git pull`) reads as having
   work. And git trims old reflog entries after 90 days by default, so a branch that
   committed once, sat idle past that and then landed can read as never moved and stays
   until dropped by hand.
2. **The worktree is clean.** `git status --porcelain` says nothing, untracked files
   included. An untracked file is work nobody has saved anywhere.

   **Gitignored files are not covered, and they go with the worktree.** `--porcelain`
   does not list them and `git worktree remove` deletes them without the refusal this
   relies on elsewhere, so a `.env`, a local database or a build cache inside a landed
   worktree is destroyed. Adding `--ignored` was considered and rejected: in a repo with
   build output under the worktree — `_build/`, `deps/`, `node_modules/` — it would refuse
   every worktree forever, which is the feature not existing. This is the same deletion
   `whiska drop` performs on the person's word; what changes is that nobody is watching
   when it happens. A worktree holding a local secret that is not in the base branch is
   the one case to take down by hand before it lands.
3. **Nothing is unpushed.** No commit on the branch is absent from every remote.
   Belt-and-braces behind the merge check, and the one that catches "merged locally into a
   base branch that itself has not been pushed".

   A branch landed as copies is exempt. Its own commits are never pushed — Land here
   lands locally, which is the point of it — so the check would hold every such worktree
   forever. Its work is as safe as the base it was copied onto, the same exposure a
   person takes on by landing locally at all. So is a branch found only in the fetched
   base: the remote already holds its work.
4. **The mouse is quiet** — see below.

**Never force.** `git worktree remove` without `--force`, `git branch -d` and not `-D`,
`worktree.remove` with `force: false`. The first is a real second opinion: git refuses to
remove a worktree with anything uncommitted in it, independently of condition 2.

`-d` is a weaker guarantee than it looks, and the difference is worth writing down because
it was measured rather than assumed: **`git branch -d` deletes an unmerged branch whose
commits are on its upstream.** Git's rule is "these commits exist somewhere else", not
"this landed in the base". So `-d` protects against losing work outright and is *not* a
second opinion on condition 1 — condition 1 stands alone, and `-d` stays because there is
no reason to reach for `-D` once it has passed. The one exception is a landing `-d` cannot
see, since it measures a branch against its upstream, or with none against what the main
checkout has out, never against where the landing was found: a branch landed as copies,
whose commits it reads as unmerged though the trial merge has just shown nothing on it is
missing from the base, and a branch only the fetched base holds. Such a branch is deleted
with `update-ref -d` only while it still points at the commit that was checked; its
branch settings stay where they are.

**Unknown is never permission.** A detached head, an unreadable git directory, a base
branch that cannot be resolved unambiguously, a git command that fails for any reason, a
herdr that does not answer — every one of them means *do nothing and leave it for the
person*. Nothing is logged as an error and nothing is retried in a tighter loop; the
worktree simply stays, and the person can still take it down by hand with `whiska drop`.

### Quiet, which replaces "dead"

The obvious precondition is ADR-0026's **dead**: the pane is gone. It is rejected, because
dead means the person closed the pane, and waiting for that makes the whole feature
attended again — the manual step moves rather than disappears. **Dead is a consequence of
cleanup, not a precondition for it.**

A **quiet** mouse is one with nothing left to do and nothing anyone is waiting on:

- **Its last word was `done`.** The worktree-status marker is the only thing a turn is
  classified by (ADR-0009), and a `done` report is the mouse saying it finished. A mouse
  whose latest question is a decision, or an unmarked stop, has not said that. A question
  the owl asked itself (ADR-0036) is not the mouse's word and is left out of this and the
  next check: it closes with the worktree.
- **None of its questions is `open` or `sent`.** Nothing of its is waiting on the person
  (ADR-0008). A pane torn down under a question the person has not answered destroys the
  only context the answer would have gone back to.
- **Its doorstep is empty of it.** A turn it has ended that the owl has not read yet is a
  question that does not exist yet, and tearing down on the strength of an older `done`
  would race it (ADR-0036).
- **herdr does not say any pane in the worktree is working.** `idle` and `done` both mean
  ready for input and both pass; `working` and `blocked` do not; `unknown` is herdr unable
  to classify the pane, so it does not either. **No pane at all passes** — that is
  ADR-0026's dead mouse, which was the old precondition and is still a perfectly good state
  to clean up from.

  **Read from herdr's own pane list, by where each pane sits, never from the mouse
  record's `pane` column.** A record whose pane match has gone stale — herdr restarted, the
  pane was re-attached, the list was momentarily short — reads as "no pane", which would
  have closed a session somebody was using on the strength of Whiska having lost track of
  it. So a pane whose working directory is inside the worktree counts whether or not the
  record knows about it, and what herdr says about the worktree has to agree with itself:
  **an open workspace with no pane in it, or a pane with no open workspace, is unknown**,
  and the worktree stays. Both halves of that were found by the reviewers on this change,
  which is the first version of it being wrong.

This is deliberately strict on one case: a branch the person merged themselves, for a mouse
that never said `done`, is never cleaned up automatically. That is the conservative side of
"unknown is never permission", and `whiska drop` still exists for it.

ADR-0026's **stuck** mouse is untouched. A stuck mouse is alive and its pane says `working`,
so it fails the fourth condition without anything here having to know what stuck means.

### The pane goes with the worktree

Removing the git worktree and leaving herdr's workspace open leaves half a thing, which is
why `whiska drop` does both (ADR-0088). The owl does what that
command does: one `worktree.remove` on herdr's socket with the workspace id, `force: false`, which
removes the worktree and closes the workspace together. A worktree with no open workspace —
the mouse was already dead — is removed with plain `git worktree remove`.

**This gives the owl a power it has never had: it can make a Claude Code session
disappear.** Until now the owl could type into a pane and nothing else, and ADR-0044 keeps
that to its own house's main session and a mouse's own work. Closing a pane is a
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

### What a mouse record is trusted for

A mouse record's `path` now decides what gets deleted, and a record is minted from a
doorstep entry — a JSON file in the repo's own `.git/whiska/doorstep/`, which anything
running in this repo can write (ADR-0036). That is a trust boundary this change moves:
before it, a forged entry could at worst produce a question nobody asked.

It is bounded rather than closed, and these are the bounds: `git worktree remove` refuses a
path that is not a registered worktree of this checkout, and herdr's workspace ids come
from its own `worktree.list` for this checkout, so only this repo's own worktrees are
reachable either way; the branch deleted is read from the worktree's own `HEAD`, never from
the record; and all four preconditions still have to hold at that path, so nothing
committed can be lost. What a forged entry buys is pointing cleanup at a worktree that
would have qualified anyway — which is why the pane rule above reads herdr rather than the
record. Anything able to write that file already runs as the person.

## Consequences

- **The sweep has a second job**
  ([ADR-0064](0064-a-landed-branch-settles-what-its-mouse-left-waiting.md)): it notes
  that a branch has landed for every mouse, not only for the ones it may tear down, so a
  question a landed mouse left waiting settles rather than orphaning. The four
  preconditions here are untouched, the third one included — a mouse with a question
  outstanding is still never torn down.
- **The mouse record gains `removed_at`**, and ADR-0007's "the row is never deleted" still
  holds — a removed mouse is permanently inert, not gone. It is already dead by then, so
  nothing on the board or in `whiska mice` changes.
- **Cleanup rides the house's existing 60 s backstop.** It is local git and one herdr call
  for a handful of dead branches; it needs no timer of its own and no event. While a merge
  request waits, the same backstop starts the base's fetch every minute, in a task of its
  own (ADR-0087).
- **`whiska cleanup` as a command is not built.** ADR-0007 named it, the spec lists it, and
  it was always the human trigger this ADR removes. If it comes back it is a *now, not in a
  minute* convenience, not the only way in.
- **`whiska drop` stays.** It is the path for everything the
  preconditions refuse, and the person's own way to take down a worktree early.
- **This is the first thing in Whiska that deletes anything.** ADR-0007's title is no longer
  true as written, which is why it is superseded here rather than quietly amended.
- **Nothing here asks a forge.** Merged is answered by git, from the base here or its copy
  last fetched; the one network call is git's fetch of the base while a merge request
  waits. The rest of following a branch after its last message — a closed request, its
  checks — is ADR-0060, which is proposed, separate, and chains onto this one rather than
  being part of it.

## Considered options

**Opt in per repo, default off.** Rejected by the person whose repos they are: the
preconditions make it safe everywhere, and a switch would mostly serve to make the feature
not happen in the repo it was asked for.

**Ask first — the owl notices and delivers "this landed, drop it?" as a question.** This is
ADR-0007's rule with better ergonomics, and it keeps a decision the person makes the same
way every time. Rejected for exactly that: a question with one sensible answer is a
notification with extra steps.

**Keep the pane and remove only the worktree.** Rejected: it is the half-teardown
`whiska drop` exists to prevent, and it would leave a Claude Code session sitting in a
folder that no longer exists.

**Archive instead of delete** — move the worktree aside rather than removing it. Rejected:
it is a folder recreatable from a merged branch, so the archive would never be read, and
ADR-0007's own reasoning (small, text-only, cheap to keep) does not apply to a checkout.

## A held mouse is left where it is

A mouse the person put on hold (ADR-0079) is left exactly where it is, landed and quiet
or not: "stops where it is" includes its worktree. Its landing is still noted, so a
question of its settles later rather than orphaning. This is checked before the four
preconditions above.

## A sniff mouse lands by its build

A sniff mouse's branch has nothing to merge, so it never lands as a branch does. Once a
build spawned from one of its questions (`whiska spawn --from`, ADR-0074) has landed and
every build from its questions is gone — taken down, dropped, or its folder taken by a
newer record — it has landed too, and the owl takes it down on a later sweep. Only a
mouse shaped sniff, and only while its branch never moved and its worktree is clean: one
that moved is asked as any other branch is, its builds aside, and a dirty one is left for
`whiska drop`. It must still be quiet and not held. Its branch goes by `update-ref -d`
only while it still points at the commit checked, as a branch landed as copies does. Its
kept research document stays.

Three cases leave it for `whiska drop`, all on the safe side. A build spawned before
builds recorded their question links to nothing. A build fast-forwarded into the base is
never stamped landed (ADR-0064), so it counts as not landed. And a build `whiska drop`
took down before a sweep saw it land is never stamped either.

Changed on 2026-10-14: a sniff mouse is taken down once its build lands (ADR-0074).

Changed on 2026-10-14: a question the owl asks itself is not the mouse's last word, and does
not hold the worktree.
