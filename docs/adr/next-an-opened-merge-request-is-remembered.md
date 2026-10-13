# An opened merge request is remembered, and its base is fetched until it lands

When the person picks "Open a merge request / PR" on a finished line, the main session
records the link on the mouse record with `whiska merge-request <id> <url>`. From then on
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

**The pick is recorded, not inferred.** The mouse record gains `merge_request_at` and
`merge_request_url`, stamped by the one command the finished-line skill runs once `gh` or
`glab` printed the link. A second record replaces the first: a new request after a closed
one. Only a plain `https://` link with a host is taken, with no space, quote, bracket or
control character in it: it is printed under the branch line, where the main session
reads it and hands it to the person. A merge request opened outside that option is not known, and its branch
keeps the ordinary options.

**Its finished lines offer what fits an open request.** The branch line reads
`merge request opened · <N> commits not pushed · …`, with `Merge request: <link>` under
it. Not pushed counts the branch's commits that no remote and no base holds. The options
are Push to the merge request, Commit and push to the merge request where files are not
committed, and none once everything is pushed. Land here, Open and Drop are not offered,
whatever `finish:` says (ADR-0022). Once the branch is seen landed, its lines are an
ordinary branch's again: new commits on it land, or go into a request of their own. A
request closed on the forge is invisible here, so `drop-worktree` stays the way out.

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

The record is what makes the options right. Inferring "in review" from git was weighed and
rejected: a branch pushed as a backup looks the same as one under review, and would lose
Land here. Asking the forge was rejected as the way to see the merge (below), so the only
thing the forge decides that Whiska needs — merged or not — is read from what a fetch
brings back, by the git checks cleanup already trusts.

## Consequences

- **The owl makes its first outbound call**, and it is git's, not a forge's: no token, no
  forge CLI, git's own credentials, and only while a request waits. ADR-0060's networked
  half is otherwise still proposed.
- **A merge request merged on the forge is taken down within minutes**, by ADR-0061's
  preconditions, read against the fetched base.
- **`origin/<base>` moves in the main checkout by itself** while a request waits. The
  local base branch never does.
- **A closed request is not seen.** Its branch keeps the merge request's options until the
  person drops it.

## Considered options

- **Ask the forge with `gh` or `glab`**, as other tools do. It sees a closed request too,
  but it polls through a write-capable login, which ADR-0060 rejects for the owl, and it
  calls a tool ADR-0085 keeps to what the person asked of a merge request.
- **Opt in per repo.** Rejected: there is no settings place to switch it in (ADR-0085), and
  the fetch cannot prompt, so on is safe everywhere.
- **Keep Drop it on a merge request's lines, last.** Rejected by the brief: Drop beside an
  open request throws away what the request still shows. `drop-worktree` covers a closed
  one.
- **An "in review" state in the sidebar.** Left out: the finished line already says it.
