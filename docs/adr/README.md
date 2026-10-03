# Architecture decisions

One file per decision, numbered in sequence. `CONTEXT.md` at the repo root is the
glossary; these record *why* things are the way they are. Both `specs/spec.md` and the
`handoffs/` files remain the long-form design narrative — these are the extracted,
individually citable decisions.

## Shape of the system

- [0001](0001-one-owl-per-machine.md) — One owl per machine, with a house per repo inside it
- [0040](0040-the-owl-is-supervised-by-a-launchagent.md) — The owl is supervised by a user LaunchAgent, and `whiska owl stop` stops the whole owl
- [0003](0003-a-house-persists-across-start-and-stop.md) — A house persists; start and stop only open and shut it
- [0020](0020-mice-stay-herdr-panes.md) — Mice stay herdr panes; Whiska never owns Claude Code directly
- [0017](0017-judgment-lives-in-claude-md.md) — All judgment lives in CLAUDE.md; Whiska stays dumb
- [0016](0016-hooks-and-rules-are-per-project.md) — Hooks and rules are per-project, not global
- [0045](0045-the-claude-md-block-is-a-nest-of-named-parts.md) — The CLAUDE.md block is a nest of named parts, and a part can be claimed
- [0055](0055-the-block-is-rules-not-prose.md) — The block is rules, not prose, and its rationale stays in Whiska's docs
- [0063](0063-a-mouse-grills-when-it-cannot-name-done.md) — A mouse grills when it cannot name "done", and builds when it can
- [0056](0056-the-global-install-is-the-same-install-rooted-at-the-home.md) — The global install is the same install rooted at the home, and the repo's copy wins
- [0035](0035-the-committed-hook-command-names-only-a-shim.md) — The committed hook command names only a shim

## Identity and security

- [0002](0002-mouse-identity-is-a-marker-file.md) — Mouse identity is an opaque marker file, not the branch or path
- [0023](0023-one-mouse-per-worktree.md) — One mouse per worktree, enforced rather than assumed
- [0024](0024-endpoint-identity-is-two-layers.md) — Endpoint identity is two layers, with an honest limit
- [0053](0053-a-session-is-identified-by-where-it-started.md) — A session is identified by where it started and which pane it runs in, never by where its shell currently is
- [0025](0025-a-second-read-only-global-socket.md) — Cross-repo visibility uses a second, read-only global socket
- [0039](0039-the-owl-records-its-open-houses-on-disk.md) — The owl records its open houses on disk, and that record is what makes a whiska

## Storage

- [0028](0028-storage-stays-sqlite.md) — Storage stays SQLite rather than reverting to flat files
- [0006](0006-both-tables-persist-live-activity-does-not.md) — Both Mouse and Question are persisted; live activity is memory-only
- [0007](0007-nothing-is-ever-deleted.md) — Nothing is ever deleted: not questions, not mice, not worktrees (the worktree half superseded 2026-10-02 by 0061)
- [0061](0061-a-merged-worktree-is-taken-down-by-the-owl.md) — A merged worktree is taken down by the owl, pane and all
- [0064](0064-a-landed-branch-settles-what-its-mouse-left-waiting.md) — A landed branch settles what its mouse left waiting (refines a line of 0007)

## Questions and delivery

- [0005](0005-answers-are-keyed-to-a-question-id.md) — Answers are keyed to a question id, not a branch
- [0008](0008-delivery-is-a-queue-not-a-batch.md) — Delivery is a queue, not a batch
- [0047](0047-delivery-holds-while-the-person-is-typing.md) — Delivery holds while the person is typing, read off the main session's prompt box
- [0036](0036-questions-are-left-on-the-doorstep.md) — Questions are left on the doorstep; the hook never opens a socket
- [0009](0009-a-missing-marker-means-deliver.md) — A missing marker means deliver; `done` is delivered too, and never waits for an answer
- [0052](0052-a-stop-with-a-subagent-still-out-is-not-a-stop.md) — A stop with a subagent still out is not a stop
- [0037](0037-a-newer-question-supersedes-its-mouses-earlier-ones.md) — A newer question supersedes its mouse's earlier open and sent ones
- [0057](0057-nothing-unanswerable-holds-the-delivery-slot.md) — Nothing that cannot be answered holds the delivery slot
- [0058](0058-a-held-queue-says-so-on-the-board.md) — A held queue says so on the board
- [0062](0062-the-owl-hoots-when-it-delivers.md) — The owl hoots when it delivers: one desktop notification per delivered question
- [0041](0041-a-nudge-is-a-notice-typed-into-another-houses-main-session.md) — A nudge is a notice typed into another house's main session (superseded 2026-09-29 by 0044)
- [0044](0044-the-statusline-redraws-on-a-timer-not-a-typed-nudge.md) — The statusline redraws on a timer, not a typed nudge (partly superseded 2026-09-29 by 0048; the refresh interval is live again on the repo-scoped line; amended 2026-10-03 by 0067 with one exception, a mouse's own pane)

## Enforcement, checks and push

- [0010](0010-hard-rules-are-enforced-by-pretooluse.md) — Hard rules are enforced by PreToolUse, not written in CLAUDE.md
- [0011](0011-pretooluse-denies-immediately.md) — PreToolUse always denies immediately; approval runs asynchronously
- [0012](0012-push-detection-via-pretooluse-not-git-hooks.md) — Push detection goes through PreToolUse, not a git pre-push hook
- [0013](0013-main-checkout-edits-are-blocked.md) — Edits in the main checkout are blocked, subagents included
- [0014](0014-checks-come-from-a-per-repo-config.md) — Whiska runs no checks of its own (superseded 2026-09-28 by 0042)
- [0015](0015-no-automated-diff-review-in-the-mvp.md) — No automated diff review in the MVP — the human is the review
- [0042](0042-the-review-loop-is-a-stop-hook-the-repo-owns.md) — The review loop is a Stop hook the repo owns (superseded 2026-09-29 by 0049)
- [0049](0049-finishing-is-a-pipeline-the-mouse-runs.md) — Finishing is a pipeline the mouse runs, not a hook that blocks it
- [0054](0054-the-reviewer-roster-is-whatever-the-session-already-has.md) — The reviewer roster is whatever the session already has, and a finding's word decides its fate (extends 0049's step 3)
- [0034](0034-shell-commands-are-judged-by-a-read-only-allowlist.md) — Shell commands are judged by a read-only allowlist, not a mutating denylist

## Mice: modes, dispatch, liveness

- [0018](0018-mouse-modes-are-build-and-sniff.md) — Mouse modes are build and sniff
- [0019](0019-model-choice-is-a-ranked-list-walked-reactively.md) — Model choice is a ranked list in dispatch.yml, walked reactively
- [0026](0026-dead-mice-and-stuck-mice-are-separate-problems.md) — Dead mice and stuck mice are separate problems
- [0050](0050-a-mouses-last-action-is-read-from-its-transcript.md) — A mouse's last action is read from its Claude Code transcript, never asked for
- [0067](0067-a-turn-that-died-is-picked-up.md) — A turn that died is picked up, once, by the owl (builds 0026's rung three; amends 0044 with its one exception)

## Interface

- [0004](0004-domain-names-house-and-owl.md) — The per-repo slice is a "house", the machine-wide process an "owl"
- [0021](0021-no-whiska-spawn-command.md) — No `whiska spawn` command — spawning happens through a conversation
- [0022](0022-each-command-gets-a-slash-command-skill.md) — Each command gets a slash-command skill, not model-composed bash
- [0046](0046-whiska-ships-the-worktree-skills.md) — Whiska ships the worktree skills, because Whiska owns the protocol (amended 2026-10-01: the source is `priv/skills/`, not the repo's own `.claude/`)
- [0027](0027-statusline-detail-for-one-count-for-many.md) — Statusline shows detail for one thing, a count for many (partly superseded 2026-09-29 by 0051: the rule is herdr's tab bar's now)
- [0051](0051-the-repo-scoped-statusline-is-a-board-the-owl-writes.md) — The repo-scoped statusline is a board, and the owl writes it to a file (amended 2026-10-01: an orphan is counted on its own line, not under "waiting"; 2026-10-02: the detail column is the mouse's topic, with the last action as the fallback; 2026-10-03: the orphan line names the branches the orphans came off; 2026-10-03: one line on it is the script's, not a mouse's row — ADR-0065)
- [0065](0065-the-board-says-when-this-pane-is-not-the-main-session.md) — The board says when this pane is not the main session, and only then
- [0066](0066-whiska-start-starts-claude-in-the-pane-it-records.md) — `whiska start` starts Claude in the pane it records
- [0059](0059-the-statusline-script-carries-a-version-stamp.md) — The statusline script carries a version stamp, and an old copy is an upgrade notice
- [0048](0048-the-owls-line-is-drawn-on-herdrs-tab-bar.md) — The owl's line is drawn once on herdr's tab bar, machine-wide, not in every Claude session (amended 2026-09-29: the repo-scoped line stays in Claude Code's statusline)
- [0038](0038-the-doctor-checks-and-probes-it-never-repairs.md) — The doctor checks and probes; it never repairs
- [0043](0043-whiska-jump-moves-the-persons-focus.md) — `whiska jump` moves the person's focus, and lands on the house's main session

## Process

- [0029](0029-rollout-runs-alongside-the-bash-relay.md) — the bash relay is gone; the cutover was hard, and the gap is accepted (reversed 2026-09-27)
- [0030](0030-v0-0-1-is-a-plain-cli-in-its-own-repo.md) — v0.0.1 is a plain CLI in its own repo, not the owl
- [0031](0031-mocking-is-confined-to-the-herdr-boundary.md) — Mocking is confined to the herdr boundary

## Performance

- [0033](0033-the-hook-client-is-native-not-elixir.md) — The hook client is a native binary, not Elixir

## Proposed, not committed

- [0032](0032-pr-opening-and-merge-tracking.md) — PR opening and merge tracking (superseded 2026-10-02 by 0060)
- [0060](0060-watching-a-branch-is-the-owls-one-networked-job.md) — Watching a branch is the owl's one networked job, and it only ever reads
