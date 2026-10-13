# An opened merge request is remembered, and its base is fetched until it lands

When the person says "pr" after a finished line, `whiska pr` opens the merge request and
records its link on the mouse record; `whiska merge-request <id> <url>` records one opened
by hand. From then on
that branch's finished lines are a merge request's, and while it waits the owl fetches the
branch it was opened against, so a merge on the forge lands it for cleanup with nobody
pulling.

## The problem, from the ordinary flow

Before this, Whiska forgot the pick the moment it was made. The mouse handled review, sent
a new finished line, and that line offered Land here (recommended), Open and Drop again,
read from git alone. Land here beside an open merge request copies its work onto the base
and leaves the request open with its work duplicated. And when the request merged on the
forge, nothing on this machine noticed: the base here had not moved, so the worktree,
pane and branch stayed until the person pulled.

## Decision

**The request is recorded, not inferred.** The mouse record gains `merge_request_at` and
`merge_request_url`, stamped by `whiska pr` once `gh` or `glab` printed the link, or by
`whiska merge-request` for one opened by hand. A second record replaces the first: a new
request after a closed one. Only a plain `https://` link with a host is taken, with no
space, quote, bracket or control character in it: it is printed under the branch line,
where the main session reads it and hands it to the person. A merge request opened any
other way and never recorded is not known, and its branch reads as an ordinary one.

**The request targets the mouse's base**, the branch its finished line names, not the
forge's default branch. The owl watches that base for the merge, so a request into any
other branch would never be seen landed and its worktree would stay. A line that names no
base leaves the target to the forge.

**Its finished lines read as an open request's.** The branch line reads `merge request
opened · <N> commits not pushed · …`, with `Merge request: <link>` under it. Not pushed
counts the branch's commits that no remote and no base holds. On "pr" again, `whiska pr`
pushes the new commits to the open request, never forced, refusing files not committed
until `--commit <file>` as it does for any branch. `whiska land` refuses a branch with a
request open: landing beside it would copy its work onto the base and leave the request
open (ADR-0088). Once the branch is seen landed, its lines are an
ordinary branch's again: new commits on it land, or go into a request of their own, which
waits until it lands in turn and moves the landing date (ADR-0064). A commit in the
fetched base is not beyond it, so a request merged on the forge leaves nothing to land. A
request closed on the forge is invisible here, so `whiska drop` stays the way out.

**While a request waits, the owl fetches its base.** Every 5 minutes on the house's
backstop, in a task of its own with a 60 s deadline, the base branch alone is fetched into
its remote-tracking branch: from the remote the base tracks, else `origin`, with no tags,
no submodules and no `FETCH_HEAD`. Nothing else in the checkout moves. A fetch that fails
waits twice as long before the next, up to an hour, and the owl's log says so once until
one works again. A failed fetch changes nothing: the worktree stays, as it does today.

**The fetch can never prompt.** It runs with `GIT_TERMINAL_PROMPT=0`,
`GCM_INTERACTIVE=never`, `SSH_ASKPASS_REQUIRE=never`, and ssh in batch mode unless the
person set an ssh command of their own. A remote that wants a password or a passphrase
fails the fetch. A key agent's own confirmation pop-up is outside git and cannot be
blocked; the owl's launchd environment fetched GitHub over ssh silently when this was
tried.

**A landing is read from the base here, then from its copy last fetched**, for every
mouse, not only one with a merge request: a fetch the person ran counts too. The checks
are ADR-0061's and ADR-0064's, unchanged, asked of the second place. A branch found only
there is deleted with `update-ref -d` while it still points at the commit checked, as a
branch landed as copies is: `git branch -d` judges it against its upstream, or what the
main checkout has out, never the fetched base where the landing was found.

## Why

The record is what makes landing and pushing right. Inferring "in review" from git was
weighed and rejected: a branch pushed as a backup looks the same as one under review, and
could no longer be landed. Asking the forge was rejected as the way to see the merge
(below), so the only thing the forge decides that Whiska needs — merged or not — is read
from what a fetch brings back, by the git checks cleanup already trusts.

## Consequences

- **The owl makes its first outbound call**, and it is git's, not a forge's: no token, no
  forge CLI, git's own credentials, and only while a request waits. ADR-0060's networked
  half is otherwise still proposed.
- **A merge request merged on the forge is taken down within minutes**, by ADR-0061's
  preconditions, read against the fetched base.
- **`origin/<base>` moves in the main checkout by itself** while a request waits. The
  local base branch never does.
- **A closed request is not seen.** Its branch reads as a merge request's, and
  `whiska land` refuses it, until the person drops it.

## Considered options

- **Ask the forge with `gh` or `glab`**, as other tools do. It sees a closed request too,
  but it polls through a write-capable login, which ADR-0060 rejects for the owl, and it
  calls a tool ADR-0085 keeps to what the person asked of a merge request.
- **Opt in per repo.** Rejected: there is no settings place to switch it in (ADR-0085), and
  the fetch cannot prompt, so on is safe everywhere.
- **Offer Drop it on a merge request's lines, last.** Rejected by the task: Drop beside an
  open request throws away what the request still shows. `whiska drop` covers a closed
  one.
- **An "in review" state in the sidebar.** Left out: the finished line already says it.

Changed on 2026-10-13: `whiska pr` opens and records the request, pushes to it once open,
and `whiska land` refuses a branch with one open, where finish options did that before
(ADR-0088).
