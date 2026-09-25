# Architecture decisions

One file per decision, numbered in sequence. `CONTEXT.md` at the repo root is the
glossary; these record *why* things are the way they are. Both `specs/spec.md` and the
`handoffs/` files remain the long-form design narrative — these are the extracted,
individually citable decisions.

## Shape of the system

- [0001](0001-one-owl-per-machine.md) — One owl per machine, with a house per repo inside it
- [0003](0003-a-house-persists-across-start-and-stop.md) — A house persists; start and stop only open and shut it
- [0020](0020-mice-stay-herdr-panes.md) — Mice stay herdr panes; Whiska never owns Claude Code directly
- [0017](0017-judgment-lives-in-claude-md.md) — All judgment lives in CLAUDE.md; Whiska stays dumb
- [0016](0016-hooks-and-rules-are-per-project.md) — Hooks and rules are per-project, not global

## Identity and security

- [0002](0002-mouse-identity-is-a-marker-file.md) — Mouse identity is an opaque marker file, not the branch or path
- [0023](0023-one-mouse-per-worktree.md) — One mouse per worktree, enforced rather than assumed
- [0024](0024-endpoint-identity-is-two-layers.md) — Endpoint identity is two layers, with an honest limit
- [0025](0025-a-second-read-only-global-socket.md) — Cross-repo visibility uses a second, read-only global socket

## Storage

- [0028](0028-storage-stays-sqlite.md) — Storage stays SQLite rather than reverting to flat files
- [0006](0006-both-tables-persist-live-activity-does-not.md) — Both Mouse and Question are persisted; live activity is memory-only
- [0007](0007-nothing-is-ever-deleted.md) — Nothing is ever deleted: not questions, not mice, not worktrees

## Questions and delivery

- [0005](0005-answers-are-keyed-to-a-question-id.md) — Answers are keyed to a question id, not a branch
- [0008](0008-delivery-is-a-queue-not-a-batch.md) — Delivery is a queue, not a batch
- [0009](0009-classification-is-the-mouses-own-marker.md) — A question's kind is the mouse's own marker, with no filtering on top

## Enforcement, checks and push

- [0010](0010-hard-rules-are-enforced-by-pretooluse.md) — Hard rules are enforced by PreToolUse, not written in CLAUDE.md
- [0011](0011-pretooluse-denies-immediately.md) — PreToolUse always denies immediately; approval runs asynchronously
- [0012](0012-push-detection-via-pretooluse-not-git-hooks.md) — Push detection goes through PreToolUse, not a git pre-push hook
- [0013](0013-main-checkout-edits-are-blocked.md) — Edits in the main checkout are blocked, subagents included
- [0014](0014-checks-come-from-a-per-repo-config.md) — Readiness checks come from a per-repo checks.yml, no tool hardcoded
- [0015](0015-no-automated-diff-review-in-the-mvp.md) — No automated diff review in the MVP — the human is the review

## Mice: modes, dispatch, liveness

- [0018](0018-mouse-modes-are-build-and-sniff.md) — Mouse modes are build and sniff
- [0019](0019-model-choice-is-a-ranked-list-walked-reactively.md) — Model choice is a ranked list in dispatch.yml, walked reactively
- [0026](0026-dead-mice-and-stuck-mice-are-separate-problems.md) — Dead mice and stuck mice are separate problems

## Interface

- [0004](0004-domain-names-house-and-owl.md) — The per-repo slice is a "house", the machine-wide process an "owl"
- [0021](0021-no-whiska-spawn-command.md) — No `whiska spawn` command — spawning happens through a conversation
- [0022](0022-each-command-gets-a-slash-command-skill.md) — Each command gets a slash-command skill, not model-composed bash
- [0027](0027-statusline-detail-for-one-count-for-many.md) — Statusline shows detail for one thing, a count for many

## Process

- [0029](0029-rollout-runs-alongside-the-bash-relay.md) — Whiska runs alongside the existing bash relay, no hard cutover
- [0030](0030-v0-0-1-is-a-plain-cli-in-its-own-repo.md) — v0.0.1 is a plain CLI in its own repo, not the owl
- [0031](0031-mocking-is-confined-to-the-herdr-boundary.md) — Mocking is confined to the herdr boundary

## Proposed, not committed

- [0032](0032-pr-opening-and-merge-tracking.md) — PR opening and merge tracking
