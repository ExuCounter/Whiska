# Architecture decisions

One file per decision, numbered in sequence. A record not yet merged is `next-<slug>.md`
and gets its number from `mix adr.claim` just before its branch merges. `CONTEXT.md` at
the repo root is the glossary; these record *why* things are the way they are. A number
missing from the sequence was folded into a surviving record on 2026-10-08, which names
it on its last line, or was dropped outright that day (0004, 0029, 0072); the old text is
in git history.

## Shape of the system

- [0001](0001-one-owl-per-machine.md) — One owl per machine, with a house per repo inside it
- [0003](0003-a-house-persists-across-start-and-stop.md) — A house persists; start and stop only open and shut it
- [0020](0020-mice-stay-herdr-panes.md) — Mice stay herdr panes; Whiska never owns Claude Code directly
- [0040](0040-the-owl-is-supervised-by-a-launchagent.md) — The owl is kept running by the platform's service manager: launchd on macOS, systemd on Linux
- [0039](0039-the-owl-records-its-open-houses-on-disk.md) — The owl records its open houses on disk, and that record is what makes a whiska
- [0033](0033-the-hook-asks-the-owl-over-a-socket.md) — The owl answers on two sockets: `hook.sock` for the hooks, `owl.sock` read-only for scripts
- [0035](0035-the-committed-hook-command-names-only-a-shim.md) — The committed hook command names only a shim
- [0056](0056-the-global-install-is-the-same-install-rooted-at-the-home.md) — The install is per-repo by default, and the global install is the same install rooted at the home
- [0081](0081-rules-arrive-by-role.md) — A session's rules arrive at session start, by its role, as rules not prose

## Identity

- [0002](0002-mouse-identity-is-a-marker-file.md) — Mouse identity is an opaque marker file, not the branch name or folder path
- [0053](0053-a-session-is-identified-by-where-it-started.md) — A session is identified by where it started and which pane it runs in
- [0030](0030-v0-0-1-is-a-plain-cli-in-its-own-repo.md) — A folder under `worktrees/` that is no checkout of its own is nobody

## Storage

- [0028](0028-storage-stays-sqlite.md) — Storage stays SQLite, and both the mouse and question tables persist
- [0007](0007-nothing-is-ever-deleted.md) — Records are kept: questions and mice are never deleted
- [0061](0061-a-merged-worktree-is-taken-down-by-the-owl.md) — A merged worktree is taken down by the owl, pane and all
- [0064](0064-a-landed-branch-settles-what-its-mouse-left-waiting.md) — A landed branch settles what its mouse left waiting

## Questions and delivery

- [0005](0005-answers-are-keyed-to-a-question-id.md) — Answers are keyed to a question id, not a branch
- [0036](0036-questions-are-left-on-the-doorstep.md) — Questions are left on the doorstep, whoever writes them
- [0009](0009-a-missing-marker-means-deliver.md) — A missing marker means deliver; `done` is delivered too, and never waits for an answer
- [0052](0052-a-stop-with-a-subagent-still-out-is-not-a-stop.md) — A stop with a subagent still out is not a stop
- [0008](0008-delivery-is-a-queue-not-a-batch.md) — Delivery is a queue, not a batch
- [0047](0047-delivery-holds-while-the-person-is-typing.md) — Delivery holds while the person is typing, read off the prompt box's frame
- [0079](0079-the-person-decides-what-reaches-them.md) — The person decides what reaches them: away, focus and hold
- [0080](0080-an-answer-is-taken-not-typed.md) — An answer is taken by the mouse's own hook, not typed into its pane
- [0062](0062-the-owl-hoots-when-it-delivers.md) — The owl hoots when it delivers
- [0044](0044-the-statusline-redraws-on-a-timer-not-a-typed-nudge.md) — Whiska types only into its own house's main session, a pickup and a doorbell aside

## Enforcement and finishing

- [0011](0011-pretooluse-denies-immediately.md) — Hard rules are a PreToolUse hook that denies at once
- [0013](0013-main-checkout-edits-are-blocked.md) — Edits in the main checkout are blocked, including anything the main session spawns
- [0034](0034-shell-commands-are-judged-by-a-read-only-allowlist.md) — Shell commands are judged by a read-only allowlist, not a mutating denylist
- [0049](0049-finishing-is-a-pipeline-the-mouse-runs.md) — Finishing is a pipeline the mouse runs, not a hook that blocks it
- [0075](0075-tests-are-scouted-then-reviewed.md) — A mouse's test is scouted before the code and reviewed at finish, when there is a test to touch

## Mice

- [0063](0063-a-mouse-asks-every-costly-choice-before-building.md) — A mouse grills every costly choice, writes the spec, and builds on the person's ok
- [0078](0078-every-task-goes-to-a-worktree.md) — Every task goes to a worktree; only the person saying "work in place" skips it
- [0069](0069-a-mouse-is-shaped-before-it-starts.md) — A mouse is shaped before it starts: mode, model and effort
- [0074](0074-a-finished-investigation-hands-off.md) — A finished investigation hands its proposal to a fresh build mouse
- [0026](0026-dead-mice-and-stuck-mice-are-separate-problems.md) — Dead mice and stuck mice are separate problems needing separate mechanisms
- [0050](0050-a-mouses-last-action-is-read-from-its-transcript.md) — A mouse's last action is read from its Claude Code transcript, never asked for
- [0067](0067-a-turn-that-died-is-picked-up.md) — A turn that died is picked up, once, by the owl

## Interface

- [0022](0022-each-command-gets-a-slash-command-skill.md) — Each command gets a slash-command skill, not model-composed bash
- [0048](0048-the-owls-line-is-drawn-on-herdrs-tab-bar.md) — The owl's line is drawn once on herdr's tab bar, machine-wide
- [0082](0082-a-mouses-state-is-a-line-in-herdrs-sidebar.md) — A mouse's state is a line in herdr's sidebar
- [0066](0066-whiska-start-starts-claude-in-the-pane-it-records.md) — `whiska start` starts Claude in the pane it records
- [0043](0043-whiska-jump-moves-the-persons-focus.md) — `whiska jump` moves the person's focus, and lands on the house's main session
- [0038](0038-the-doctor-checks-and-probes-it-never-repairs.md) — The doctor checks and probes; it never repairs

## Process

- [0031](0031-mocking-is-confined-to-the-herdr-boundary.md) — Mocking is confined to the herdr boundary
- [0070](0070-an-adr-claims-its-number-when-it-lands.md) — An ADR claims its number when it lands

## Proposed, not built

- [0024](0024-endpoint-identity-is-two-layers.md) — Endpoint identity is two layers, with an honest limit; one mouse per worktree is enforced through it
- [0060](0060-watching-a-branch-is-the-owls-one-networked-job.md) — Watching a branch is the owl's one networked job, and it only ever reads
