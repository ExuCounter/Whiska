# Architecture decisions

One file per decision, numbered in sequence. A record not yet merged is `next-<slug>.md`
and gets its number from `mix adr.claim` just before its branch merges. `CONTEXT.md` at
the repo root is the glossary; these record *why* things are the way they are. Both
`specs/spec.md` and the `handoffs/` files remain the long-form design narrative — these
are the extracted, individually citable decisions.

## Shape of the system

- [0001](0001-one-owl-per-machine.md) — One owl per machine, with a house per repo inside it
- [0040](0040-the-owl-is-supervised-by-a-launchagent.md) — The owl is supervised by a user LaunchAgent, and `whiska owl stop` stops the whole owl (amended 2026-10-05 by ADR-0077: launchd is macOS's half)
- [0077](0077-the-owl-is-kept-by-the-platforms-service-manager.md) — The owl is kept running by the platform's own service manager: launchd on macOS, systemd on Linux (amends 0040)
- [0003](0003-a-house-persists-across-start-and-stop.md) — A house persists; start and stop only open and shut it
- [0020](0020-mice-stay-herdr-panes.md) — Mice stay herdr panes; Whiska never owns Claude Code directly
- [0017](0017-judgment-lives-in-claude-md.md) — All judgment lives in CLAUDE.md; Whiska stays dumb (amended 2026-10-06 by 0081: the rules arrive at session start)
- [0016](0016-hooks-and-rules-are-per-project.md) — Hooks and rules are per-project, not global
- [0045](0045-the-claude-md-block-is-a-nest-of-named-parts.md) — The CLAUDE.md block is a nest of named parts, and a part can be claimed (amended 2026-10-06 by 0081: the parts are printed by a hook, and init takes the block out)
- [0055](0055-the-block-is-rules-not-prose.md) — The block is rules, not prose, and its rationale stays in Whiska's docs (amended 2026-10-06 by 0081: the report part drops the general voice rules)
- [0081](0081-rules-arrive-by-role.md) — A session's rules arrive at session start, by its role: none outside herdr, the main session's, a mouse's; six one-word skills never load into context (amends 0017, 0022, 0045, 0055, 0056)
- [0063](0063-a-mouse-asks-every-costly-choice-before-building.md) — A mouse reads the code, then asks every choice that is costly to undo (rewritten 2026-10-04: it grilled only when it could not name "done"; amended 2026-10-05 by ADR-0076: a spec follows the grilling)
- [0076](0076-a-grilled-brief-is-written-down-before-it-is-built.md) — A grilled brief is written down as a spec, in a file git ignores, and approved before it is built; Whiska ships `grilling` and `whiska-spec` (amends 0063; amended 2026-10-07: the template keeps its headings, the spec is about 500 words)
- [0056](0056-the-global-install-is-the-same-install-rooted-at-the-home.md) — The global install is the same install rooted at the home, and the repo's copy wins (amended 2026-10-04: it ships the three worktree skills too; amended 2026-10-06 by 0081: a SessionStart hook, not a block)
- [0035](0035-the-committed-hook-command-names-only-a-shim.md) — The committed hook command names only a shim (noted 2026-10-07: only the shim changed when the hook moved onto the owl, as promised)

## Identity and security

- [0002](0002-mouse-identity-is-a-marker-file.md) — Mouse identity is an opaque marker file, not the branch or path
- [0023](0023-one-mouse-per-worktree.md) — One mouse per worktree, enforced rather than assumed
- [0024](0024-endpoint-identity-is-two-layers.md) — Endpoint identity is two layers, with an honest limit
- [0053](0053-a-session-is-identified-by-where-it-started.md) — A session is identified by where it started and which pane it runs in, never by where its shell currently is
- [0025](0025-a-second-read-only-global-socket.md) — Cross-repo visibility uses a second, read-only global socket (built 2026-10-07: `owl.sock` answers `waiting`, `show` and `line` for the person's scripts and the tab bar; the hooks ask a private `hook.sock` beside it)
- [0039](0039-the-owl-records-its-open-houses-on-disk.md) — The owl records its open houses on disk, and that record is what makes a whiska

## Storage

- [0028](0028-storage-stays-sqlite.md) — Storage stays SQLite rather than reverting to flat files
- [0006](0006-both-tables-persist-live-activity-does-not.md) — Both Mouse and Question are persisted; live activity is memory-only
- [0007](0007-nothing-is-ever-deleted.md) — Nothing is ever deleted: not questions, not mice, not worktrees (the worktree half superseded 2026-10-02 by 0061)
- [0061](0061-a-merged-worktree-is-taken-down-by-the-owl.md) — A merged worktree is taken down by the owl, pane and all (amended 2026-10-06 by ADR-0079: a fifth precondition, not held)
- [0064](0064-a-landed-branch-settles-what-its-mouse-left-waiting.md) — A landed branch settles what its mouse left waiting (refines a line of 0007)

## Questions and delivery

- [0005](0005-answers-are-keyed-to-a-question-id.md) — Answers are keyed to a question id, not a branch
- [0008](0008-delivery-is-a-queue-not-a-batch.md) — Delivery is a queue, not a batch (noted 2026-10-06: a finished line waits for the slot, and still never holds it)
- [0047](0047-delivery-holds-while-the-person-is-typing.md) — Delivery holds while the person is typing, read off the main session's prompt box (amended 2026-10-03 and 2026-10-04 by 0068)
- [0068](0068-the-prompt-box-is-found-by-its-frame.md) — The prompt box is found by its frame, and no box on screen holds delivery (amends 0047; amended 2026-10-04: faint text in the box is not a draft)
- [0036](0036-questions-are-left-on-the-doorstep.md) — Questions are left on the doorstep, whoever writes them (amended 2026-10-07 by ADR-0033: the hook asks the owl first and the owl writes the entry; the escript writes it when the owl does not answer)
- [0009](0009-a-missing-marker-means-deliver.md) — A missing marker means deliver; `done` is delivered too, and never waits for an answer (noted 2026-10-06: `done` means the brief is done, and files not committed are offered a commit first)
- [0052](0052-a-stop-with-a-subagent-still-out-is-not-a-stop.md) — A stop with a subagent still out is not a stop
- [0037](0037-a-newer-question-supersedes-its-mouses-earlier-ones.md) — A newer question supersedes its mouse's earlier open and sent ones
- [0057](0057-nothing-unanswerable-holds-the-delivery-slot.md) — Nothing that cannot be answered holds the delivery slot (amended 2026-10-06 by ADR-0079: nor does a held or unfocused sent question)
- [0058](0058-a-held-queue-says-so-on-the-board.md) — A held queue says so on the board (amended 2026-10-06 by ADR-0079: the word is "gated"; amended 2026-10-07 by ADR-0082: said on the main checkout's sidebar line)
- [0079](0079-the-person-decides-what-reaches-them.md) — The person decides what reaches them: away is the machine's, a focus is one repo's, a hold is one mouse's stored status, stopped through the hook; eight one-word commands; the gate's word is "gated" (amends 0008, 0022, 0043, 0057, 0058, 0061, 0067)
- [0080](0080-an-answer-is-taken-not-typed.md) — An answer is taken by the mouse's own hook, not typed into its pane: `reply` saves it and rings a doorbell, a `UserPromptSubmit` hook hands it over and stamps it taken, and the owl rings again at most three times before telling the person (amends 0044, 0067)
- [0062](0062-the-owl-hoots-when-it-delivers.md) — The owl hoots when it delivers: one desktop notification per delivered question (amended 2026-10-04 by ADR-0071)
- [0071](0071-a-hoot-reaches-you-without-herdr.md) — A hoot herdr will not show is raised on the desktop (amends 0062; noted 2026-10-05: notify-send on Linux)
- [0041](0041-a-nudge-is-a-notice-typed-into-another-houses-main-session.md) — A nudge is a notice typed into another house's main session (superseded 2026-09-29 by 0044)
- [0044](0044-the-statusline-redraws-on-a-timer-not-a-typed-nudge.md) — The statusline redraws on a timer, not a typed nudge (partly superseded 2026-09-29 by 0048; the refresh interval is live again on the repo-scoped line; amended 2026-10-03 by 0067 with one exception, a mouse's own pane; amended 2026-10-06 by ADR-0080 with a second, the doorbell; amended 2026-10-07 by ADR-0082: no repo-scoped line is left to redraw)

## Enforcement, checks and push

- [0010](0010-hard-rules-are-enforced-by-pretooluse.md) — Hard rules are enforced by PreToolUse, not written in CLAUDE.md
- [0011](0011-pretooluse-denies-immediately.md) — PreToolUse always denies immediately; approval runs asynchronously
- [0012](0012-push-detection-via-pretooluse-not-git-hooks.md) — Push detection goes through PreToolUse, not a git pre-push hook
- [0013](0013-main-checkout-edits-are-blocked.md) — Edits in the main checkout are blocked, subagents included
- [0014](0014-checks-come-from-a-per-repo-config.md) — Whiska runs no checks of its own (superseded 2026-09-28 by 0042)
- [0015](0015-no-automated-diff-review-in-the-mvp.md) — No automated diff review in the MVP — the human is the review
- [0042](0042-the-review-loop-is-a-stop-hook-the-repo-owns.md) — The review loop is a Stop hook the repo owns (superseded 2026-09-29 by 0049)
- [0049](0049-finishing-is-a-pipeline-the-mouse-runs.md) — Finishing is a pipeline the mouse runs, not a hook that blocks it (amended 2026-10-04 by ADR-0075: a fifth axis, tests; noted 2026-10-06: a sixth step, commit the work; amended 2026-10-07 by ADR-0083: axes chosen by the diff, an agent ledger; amended by ADR-0084: a disputed finding stays)
- [0054](0054-the-reviewer-roster-is-whatever-the-session-already-has.md) — The reviewer roster is whatever the session already has, and a finding's word decides its fate (extends 0049's step 3; amended 2026-10-04 by ADR-0075: a fifth axis, tests; amended 2026-10-07 by ADR-0083: axes chosen by the diff; amended by ADR-0084: a disputed finding stays)
- [0072](0072-a-reviewer-is-chosen-by-the-diff.md) — Reviewers are a required set plus what the repo's CLAUDE.md calls for, with no config (proposed, not applied; amends 0049, 0054 and 0056; its wio row narrowed 2026-10-04 by ADR-0075; two rows applied 2026-10-07 by ADR-0083)
- [0075](0075-tests-are-scouted-then-reviewed.md) — A mouse's test is scouted before the code and reviewed at finish, when there is a test to touch (follows 0063 and 0055; adds a fifth axis to 0049 and 0054, and one exception to 0054's written-prompt fallback; scout gated 2026-10-07 by ADR-0083)
- [0083](0083-reviewers-by-trigger.md) — Reviewers are chosen by what the diff does, and every finished report ends with an agent ledger (amends 0049, 0054, 0075; applies two rows of 0072; its correctness row and small-diff reviewer amended by ADR-0084)
- [0084](0084-the-correctness-review-is-cold.md) — The correctness review is cold, and every reviewer's findings reach the person whole (amends 0083, 0049, 0054)
- [0034](0034-shell-commands-are-judged-by-a-read-only-allowlist.md) — Shell commands are judged by a read-only allowlist, not a mutating denylist

## Mice: modes, dispatch, liveness

- [0018](0018-mouse-modes-are-build-and-sniff.md) — Mouse modes are build and sniff (noted 2026-10-04, rewritten 2026-10-06: a mouse has one mode)
- [0019](0019-model-choice-is-a-ranked-list-walked-reactively.md) — Model choice is a ranked list in dispatch.yml, walked reactively (superseded 2026-10-03 by 0069)
- [0069](0069-a-mouse-is-shaped-before-it-starts.md) — A mouse is shaped before it starts, and its shape carries its model (makes 0018 reachable and rewrites its default; supersedes 0019; amended 2026-10-04 by ADR-0073)
- [0073](0073-model-and-effort-are-chosen-by-ordered-rules.md) — Model and effort are chosen by ordered rules, apart from the mode, and the model that ran is recorded (amends 0069)
- [0074](0074-a-finished-investigation-hands-off.md) — A finished investigation hands its proposal to a fresh build mouse; `whiska mode` gives a mode to a mouse nobody shaped and refuses a shaped one (follows from 0069 and 0073; revised 2026-10-06: the flip is gone; offered for any branch with nothing on it, not only a sniff mouse's)
- [0026](0026-dead-mice-and-stuck-mice-are-separate-problems.md) — Dead mice and stuck mice are separate problems
- [0050](0050-a-mouses-last-action-is-read-from-its-transcript.md) — A mouse's last action is read from its Claude Code transcript, never asked for
- [0067](0067-a-turn-that-died-is-picked-up.md) — A turn that died is picked up, once, by the owl (builds 0026's rung three; amends 0044 with its one exception; amended 2026-10-06 by ADR-0079: a held mouse is never picked up; amended 2026-10-06 by ADR-0080: a turn begins at the take, and a chased answer is not a died turn; amended 2026-10-07: an API error in the transcript skips the settling window)
- [0078](0078-every-task-goes-to-a-worktree.md) — Every task goes to a worktree; only the person saying "work in place" skips it (amends 0063, 0075 and 0076: a tweak or quick fix no longer skips the scout or the spec)

## Interface

- [0004](0004-domain-names-house-and-owl.md) — The per-repo slice is a "house", the machine-wide process an "owl"
- [0021](0021-no-whiska-spawn-command.md) — No `whiska spawn` command — spawning happens through a conversation
- [0022](0022-each-command-gets-a-slash-command-skill.md) — Each command gets a slash-command skill, not model-composed bash (amended 2026-10-06 by ADR-0079: the one-word skills replace the two long-named ones, `/inbox` ships, the picker lands by cherry-pick; and by 0081: six of them never load into context)
- [0046](0046-whiska-ships-the-worktree-skills.md) — Whiska ships the worktree skills, because Whiska owns the protocol (amended 2026-10-01: the source is `priv/skills/`, not the repo's own `.claude/`; its dotfiles follow-up landed in 0056's 2026-10-04 amendment)
- [0027](0027-statusline-detail-for-one-count-for-many.md) — Statusline shows detail for one thing, a count for many (partly superseded 2026-09-29 by 0051: the rule is herdr's tab bar's now)
- [0051](0051-the-repo-scoped-statusline-is-a-board-the-owl-writes.md) — The repo-scoped statusline is a board, and the owl writes it to a file (amended 2026-10-01: an orphan is counted on its own line, not under "waiting"; 2026-10-02: the detail column is the mouse's topic, with the last action as the fallback; 2026-10-03: the orphan line names the branches the orphans came off; 2026-10-03: one line on it is the script's, not a mouse's row — ADR-0065; 2026-10-04: elapsed time ticks in seconds, redrawn every second, herdr still asked every two; superseded 2026-10-07 by ADR-0082: the mice's state is a line in herdr's sidebar)
- [0065](0065-the-board-says-when-this-pane-is-not-the-main-session.md) — The board says when this pane is not the main session, and only then (amended 2026-10-07 by ADR-0082: only "no main session" survives, on the main checkout's sidebar line)
- [0066](0066-whiska-start-starts-claude-in-the-pane-it-records.md) — `whiska start` starts Claude in the pane it records
- [0059](0059-the-statusline-script-carries-a-version-stamp.md) — The statusline script carries a version stamp, and an old copy is an upgrade notice (superseded 2026-10-07 by ADR-0082: there is no script)
- [0048](0048-the-owls-line-is-drawn-on-herdrs-tab-bar.md) — The owl's line is drawn once on herdr's tab bar, machine-wide, not in every Claude session (amended 2026-09-29: the repo-scoped line stays in Claude Code's statusline; amended 2026-10-07 by ADR-0082: it moves to herdr's sidebar; amended 2026-10-07: the script asks the owl's socket and starts nothing, says `owl down` with no count when nothing answers, and shows the jump key the person passes it)
- [0082](0082-a-mouses-state-is-a-line-in-herdrs-sidebar.md) — A mouse's state is a line under its own workspace in herdr's sidebar, written by the owl and coloured by its first symbol; the main checkout's line says what is true of the repo; the mice re-sort only when one starts or stops needing the person; the Claude Code statusline goes (supersedes 0051, 0059; amends 0044, 0048, 0058, 0065)
- [0038](0038-the-doctor-checks-and-probes-it-never-repairs.md) — The doctor checks and probes; it never repairs
- [0043](0043-whiska-jump-moves-the-persons-focus.md) — `whiska jump` moves the person's focus, and lands on the house's main session (amended 2026-10-06 by ADR-0079: `waiting` has a slash command, `/inbox`, typed by the person; `jump` still has none; 2026-10-06: `whiska open <id|branch>` is a separate move into a mouse's own pane)

## Process

- [0029](0029-rollout-runs-alongside-the-bash-relay.md) — the bash relay is gone; the cutover was hard, and the gap is accepted (reversed 2026-09-27)
- [0030](0030-v0-0-1-is-a-plain-cli-in-its-own-repo.md) — v0.0.1 is a plain CLI in its own repo, not the owl
- [0031](0031-mocking-is-confined-to-the-herdr-boundary.md) — Mocking is confined to the herdr boundary
- [0070](0070-an-adr-claims-its-number-when-it-lands.md) — An ADR claims its number when it lands

## Performance

- [0033](0033-the-hook-asks-the-owl-over-a-socket.md) — The hook asks the owl over a socket, from bash, with the escript behind it (rewritten 2026-10-07: it said the hook would be a native binary; dropped)

## Proposed, not committed

- [0032](0032-pr-opening-and-merge-tracking.md) — PR opening and merge tracking (superseded 2026-10-02 by 0060)
- [0060](0060-watching-a-branch-is-the-owls-one-networked-job.md) — Watching a branch is the owl's one networked job, and it only ever reads
