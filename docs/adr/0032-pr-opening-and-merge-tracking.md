---
status: proposed
---

# PR opening and merge tracking — designed, not committed

How often these worktree branches actually go through a PR is a genuine 50/50, so this is
not built for the MVP. The shape is worked out for whenever it is wanted, recorded here so
it does not get redesigned from scratch:

- Opt-in per repo, a `pr: true` line alongside `checks.yml` — off by default, matching
  today's behaviour (stop at push, handle PRs and merges yourself).
- When on, after a push succeeds Whiska tells the mouse to open the PR itself, since the
  mouse has the context to write a real title and summary and Whiska stays dumb on purpose.
- Whiska does not trust the mouse's self-report: it confirms the PR exists by asking GitHub
  directly (`gh pr list --head <branch>`) — the same "verify mechanically, don't trust the
  model's word" principle used for push detection and readiness checks.
- The existing sweep, already polling for dead panes, gets one more job for branches with an
  open PR: check `gh pr view --json mergeable,statusCheckRollup` until it is actually green.
- Once green it becomes a normal question — "PR #42 is green and mergeable — merge it?" —
  through the same path as push approval. Yes means Whiska runs `gh pr merge` itself, purely
  mechanical.
