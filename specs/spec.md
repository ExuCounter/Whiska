# Whiska — spec draft v2

Status: grilled once with the user (2026-09-24), most core decisions locked. A few
implementation details still open — see "Still needs deciding."

## Problem

Today a human-facing Claude session has to notice by hand when a worker needs a
decision, go fetch what it said, pass it to the user, then manually send the answer
back. Slow. And no answer is tied to a specific question — if a branch has two open
questions at once, an answer could land on the wrong one.

## What stays the same

- herdr: creates panes, starts Claude Code, tracks status. Unchanged.
- Claude Code: unchanged. Its `Stop` hook already hands over the full message + the
  folder it's running in.
- A mouse = a herdr pane running Claude Code. Not a new thing to build, just a name.

## What's new

**One Whiska owl per machine, not one process per repo.** Revised from an earlier
draft of this spec, which had `whiska init`/`whiska start` spin up a fully separate OS
process per repo. That fought the grain of how `launchd`/`brew services` actually
supervises things (one long-running service, cleanly auto-restarted — not N processes
coming and going as you open and close repos), and it made "stop just this repo" and
"see what's waiting on me across every project" both awkward to build.

Fixed by using Elixir/OTP the way it's meant to be used: `brew install whiska` installs
one binary, supervised as a single background service. Every repo you `whiska start` in
gets its own **house, supervised inside that one process** — its own Unix socket, its
own SQLite connection, its own sweep timer — logically isolated from every other repo's
house, the same isolation as before, just inside one process instead of many.

**Nothing about security gets weaker.** The property that mattered — a rogue process
can't guess a shared port, it has to already be inside a specific repo to find that
repo's socket — came from the socket living at a path under that specific repo's own
`.git/`, not from being a separate OS process. One process can listen on many separate
sockets at once; each repo's socket is exactly as private as it was before.

**And it's what makes cross-repo visibility cheap** (see "Seeing across every project"
below) — the owl already holds every active repo's state in memory, in one place, so
"what's open anywhere" is one more query against something that already knows the
answer, not a new process talking to N other processes over some new protocol.

- Each repo's socket only ever handles that repo's own traffic — hook events, push
  approval, mouse identity. Every request must present the actual marker-file content,
  not just claim an id; Whiska cross-checks it against worktrees it actually remembers
  creating, and rejects anything it doesn't recognize. Not a full identity system, still
  worth hardening further later — see "Still needs deciding."
- Marker (`[worktree-status: ...]`) is prefixed with an invisible Unicode character
  (same trick as firstmate), so it never shows up when reading the transcript — only
  the hook can see it. Real risk worth flagging: getting a model to reliably emit an
  exact invisible character every time isn't guaranteed the way plain text is.
- One saved `Question` table and one saved `Mouse` table per repo house (see "What
  gets saved" below) — repo is implicit, it's whichever house they belong to.

**`whiska`**: the command-line tool, same name as the project. Commands:
- `whiska init` — writes the repo's hooks.
- `whiska start` — starts your main session.
- `whiska questions` — lists open questions (what's actually waiting on you). Named for
  exactly what it shows, not the overloaded "status" (which reads, in most CLIs, as "show
  me everything" — `git status`, `docker status` — and would be confused with
  `whiska mice`). Mainly for browsing the backlog on demand — e.g. after `whiska quiet`
  held a bunch of them — since normal delivery already pushes each question to you in
  full, one at a time, without needing to ask. The statusline's open-question count (see
  "Statusline" below) reads the same underlying data directly — it doesn't shell out to
  this command.
- `whiska reply <id> "..."` — answers anything, including a push approval (same command
  either way, since push approval reuses the normal question system).
- `whiska diff <id>` — shows the full diff for a pending push question, straight to the
  terminal (`git -C <worktree> diff`), so you can actually read the change before
  answering. Not built into the question itself by default (too long for a status-line
  question), just one command away.
- `whiska mice` — lists what's currently alive (branch, mode, status, uptime) — separate
  from `questions`, since a mouse can be running fine with nothing pending. Shows a short
  excerpt of current activity per mouse too — see "Knowing what a mouse is doing" below
  for where that comes from.
- `whiska doctor` — sanity check: is the owl running, is this repo's house open and
  registered and its hooks correctly installed, does the marker file look right, is
  herdr reachable. Also checks the external tools a repo actually depends on, not just
  Whiska's own state — `git`, `herdr` itself (reachable, right version), and `gh` if
  `pr: true` is set for that repo. Same reasoning as firstmate's own bootstrap check:
  don't let work start until the tools it needs are actually confirmed present.
- `whiska quiet` / `whiska loud` — pause delivery without losing anything (still tracked,
  still queued, just held), then un-pause and immediately flush whatever piled up.
  Manual version of the same "hold while busy" idea, triggered by you instead of
  inferred from pane state.
- `whiska stop` — shuts *this repo's* house only (closes its socket, stops its
  sweep, drops its supervision; the house, its database and its mouse records stay).
  The owl itself keeps running for every other repo; nothing forces killing it, and if
  nothing's left active it just idles at near-zero cost rather than exiting.
- `whiska projects` — one row per repo with an open house right now, showing its
  mouse count and open-question count. Run from **anywhere on the machine**, not just
  inside a repo — it's the one command that isn't repo-scoped, since it talks to the
  owl's own machine-wide view, not one repo's socket. Supports `--json` for scripting
  (Raycast, anything else) — structured output of the same rows.
- `whiska goto <project>` — asks herdr to focus that project's main session pane
  directly, from wherever you currently are. Herdr already knows how to focus a specific
  pane (same mechanism `spawn-worktree` uses, just the reverse of `--no-focus`); since
  the owl already tracks every project's main-session pane machine-wide, this is just
  one more query against data it already has. Use this when you want the full context
  (read more, look at the diff) — `whiska reply <id> "..."` already works from anywhere
  without needing to jump at all, for when you already know what you want to say.
- `whiska reopen <branch>` — starts a fresh pane for a dead mouse, pointed at its
  worktree folder (still on disk), and delivers its last saved question as the first
  message. See "Staying alive" below for the full step-by-step.
- `whiska cleanup <branch>` — removes a worktree for good, but only after checking the
  branch is actually merged; refuses without an explicit override ("never tear down
  unlanded work"). See "Rules for mice" below.
- `whiska update` — re-writes this repo's `CLAUDE.md` block and installed skills to
  whatever the current installed version ships, without touching anything else in the
  file. Opt-in per project — upgrading Whiska itself (`brew upgrade`) never touches a
  project automatically. See "CLAUDE.md" below.

Deliberately not building: `whiska spawn`. Spawning a mouse is a judgment call (mode,
model, is this even worth a worktree) that belongs in a conversation with the main
session, not a bare command with no thinking behind it — keep it something that happens
*through* a conversation, not its own command.

`whiska history <branch>` considered, left out for now — genuinely useful sometimes
("why did I decide that, weeks ago"), but not core to the system working day to day.
Build if it's actually missed, not preemptively.

## Two ways in: typed by you, or run by your session

Not every command belongs to the same person. `whiska start` *creates* the Claude Code
session — it can't be something Claude runs for you, since Claude isn't running yet when
you need it. That one fact draws the whole line:

- **Typed directly by you, outside/before a Claude session:** `whiska init`,
  `whiska start`, `whiska stop`, `whiska doctor`, `whiska update` (you'd reach for these
  exactly when something's broken or being upgraded, often before a session exists).
- **Used by your main Claude session, on your behalf, once one's running:**
  `whiska questions`, `whiska reply`, `whiska diff`, `whiska mice`, `whiska quiet`,
  `whiska loud`, `whiska reopen`, `whiska cleanup` — all natural to ask for in plain
  conversation ("reopen the auth-fix worktree," "clean up the old feature branch").
- **Machine-wide, not tied to any one repo's session — `whiska projects`,
  `whiska goto`.** These talk to the owl's own global socket, not a repo's, so they
  work equally well typed in a plain terminal or asked of whichever Claude session
  you're currently in — there's no "the right repo" for the main session to run them in.

For the second group, don't rely on the model translating your plain English into the
right Bash call each time — same lesson as the worktree-relay fix, less surface for the
model to get wrong or forget. Instead, `whiska init` also installs a matching Claude
Code skill per command (`.claude/skills/`, same pattern firstmate actually uses for
`/afk`, `/quiet`, `/ahoy`) — real slash commands (`/whiska-questions`, `/whiska-reply`,
`/whiska-quiet`, ...), discoverable via `/help`, not an implicit hope the model picks
the right underlying call. The skill is a thin wrapper: it just runs the fixed `whiska`
command, nothing more — same command either way, just a reliable, visible way to invoke
it instead of an implicit one.

## Starting your main session

`whiska start`:
1. Checks you're already inside a herdr pane (same precondition check `spawn-worktree`
   already does — `HERDR_ENV=1`, etc.). If not, stops and says so.
2. Starts Claude Code in the current pane — no new pane gets created, you're already in
   one.
3. Whiska records this pane as the main session for whichever repo you're in. No
   separate "attach" step: Whiska knows because it's the one that started it.

## How Whiska knows which mouse

**Identity is a hidden marker file, not the branch name or the folder path.** Neither of
those is actually stable — a branch can be renamed any time (people do this casually),
a worktree folder can be moved, and in principle someone could even check out a
different branch inside an existing worktree folder later. None of that should break
tracking, so none of it is the key.

Instead: the moment Whiska asks herdr to create a worktree, it drops a small hidden
file at the worktree's root (same pattern already proven in this repo —
`.herdr-worktree-meta` does exactly this for pane tracking) containing one opaque,
Whiska-minted id. Written once, by a script, never by the model — the hook just reads
it, same complexity as reading a branch name, no parsing involved. Gitignored, same as
the existing meta file.

This file survives everything that would break branch- or path-based keying: renaming
the branch doesn't touch it, moving the folder carries it along automatically (it's
just a regular file), and checking out a different branch inside the same worktree
later doesn't remove it either — git only touches *tracked* files on checkout, and this
one never is.

Branch name and folder path stay useful — as live, re-read *labels* for display (what
`whiska mice` shows you), never as the lookup key.

Whiska keeps `id → pane`, saved once when it asks herdr to open that pane. To answer a
mouse: look up its pane, ask herdr to type the answer there. The main session works the
same way — it's just the one pane this repo's Whiska instance was started from.

`whiska reply` and `whiska diff` take a **question id**, not a branch — on purpose, the
same reason ids exist at all: a branch can have two open questions at once, and a
branch-keyed answer would land on whichever one Whiska guessed, reintroducing the exact
mismatched-answer problem this system exists to fix.

Commands that act on the worktree/mouse as a whole instead of one specific question —
`whiska reopen`, `whiska cleanup` — take a plain branch name. No ambiguity there: a
worktree only has one branch checked out at a time, so branch is a fine, convenient
lookup against whatever's currently live (not how anything's actually stored).

## One mouse per worktree — enforced, not assumed

Why this needs a real rule: two live panes reading the same marker file would fight over
the same `mouse_id` — Whiska couldn't tell which pane a reply should go to, and the
"what's it doing" excerpt would flip between two unrelated activities. This has to be
prevented mechanically, not just hoped for, same reasoning as everything else enforced
in this spec rather than left as a written rule.

No new machinery needed — two things already designed elsewhere solve it directly:

- **Same refusal shape as "two `whiska start` for the same repo"** (see "Still needs
  deciding" below): if a hook event claims a `mouse_id` that already has a different,
  still-alive pane on record, refuse it and name the existing pane. Identical pattern,
  just applied to mice instead of the main session.
- **The kernel-level peer-PID check (already designed against spoofing) does the actual
  detection.** A second, unrelated pane trying to use the same worktree shows up as a
  genuinely different PID than the one already recorded for that `mouse_id` — the exact
  signal already built for security also happens to be exactly what's needed here.

## Mouse mode: build vs. sniff

Idea borrowed from firstmate's Ship/Scout, renamed to fit our own words. Same kind of
mouse either way, just a mode flag:

- **build** — produces a real change. Default mode, current rules apply (edits confined
  to its own worktree, push needs approval).
- **sniff** — investigation only. Writes a report, never a PR. `PreToolUse` blocks
  *all* edits, not just ones outside the worktree — a sniff mouse should never write
  code at all.

**Model/effort choice:** the main session can always override per task, same judgment
call it already makes for "does this need a worktree at all." The *default*, though,
comes from a small static config, not a hardcoded rule — same agnostic shape as
`checks.yml`. `whiska init` scaffolds `.whiska/dispatch.yml`:

```yaml
# Ranked per mode — Whiska tries the first, falls back to the next only on an
# actual failure (a real rate-limit/quota error), never guessed ahead of time.
build:
  - sonnet
  - opus
sniff:
  - haiku
  - sonnet
```

**Reactive, not predictive** — same "verify mechanically, don't guess ahead of time"
principle running through the rest of this spec. Whiska doesn't check quota or usage
before spawning (that means integrating with whatever quota API each provider happens
to expose, inconsistent, some may not even have one). It just tries the first entry;
if the spawn itself actually fails with a real quota/rate-limit error, it tries the next
one down the list. No live usage-tracking, no per-provider integration — a plain ranked
list, walked in order, only moving on when something genuinely didn't work.

Static for now, on purpose — if this later needs to shift based on real usage patterns
(prefer whichever account has quota left *today*), that's a real feature to add on top
later, not something to build speculatively now.

## What gets saved

```
Mouse:    mouse_id (the marker-file id, the real key),
          pane, path, branch (live labels, re-read for display, not the key),
          mode (build/sniff), created_at

Question: id (plain incrementing number, global within this repo's Whiska instance),
          mouse_id (foreign key into Mouse),
          full text, kind, status (open/sent/answered/orphaned), when, answer
```

Both tables live in SQLite, persisted — not just `Mouse` in memory. This matters for
restart recovery: the startup sweep (see "Staying alive" below) checks whether each
mouse's pane still exists, which only works if `pane`/`path` survive a Whiska restart in
the first place. Losing this on restart would silently break `reply`/`diff` for every
live mouse until something rediscovers them — and nothing currently would. The
"knowing what a mouse is doing" excerpt stays in memory only, as already decided — that
one's genuinely fine to lose, this one isn't.

`branch` isn't the lookup key, per "How Whiska knows which mouse" above — it's a live,
re-read label for display, looked up via `mouse_id`.

Two simple tables instead of a folder of files, a lock, and separate tracking files.
Fixes the mismatched-answer problem: an answer points at a specific question's id, not
just "whatever's in this pane right now."

**Answered questions are kept forever, not cleaned up** — it's a small table of text and
doubles as a free history of every decision made.

## How it flows

1. `whiska start` in a repo → that pane becomes the main session for that repo.
2. `whiska init` in a repo → writes the repo's own `.claude/settings.json` with the
   `Stop` and `PreToolUse` hooks (see below), checked into git so it travels with the
   repo.
3. Whiska asks herdr to open a mouse's pane + Claude session, drops the hidden marker
   file (its stable id) into the worktree root, saves id → pane.
4. A mouse finishes a turn needing a decision → its hook reads the marker file, sends
   Whiska the message with that id. If Whiska isn't running, this fails loudly — never
   silently.
5. Whiska saves it as a new question. Classification is purely the marker the mouse
   wrote (`done` vs `needs-decision`) — no extra filtering on top.
6. Whiska only ever delivers to the main session when it's idle *and* has no other
   open, unanswered question sitting there already. Otherwise, a new question just
   joins the pile silently — no interruption, no timer needed for this part. This
   alone is what stops you from getting pinged twice for things that land close
   together; it's a plain queue, not a batch.
7. The one place an 8-second window still earns its keep: the very first question of a
   fresh round (main session idle, nothing open) waits up to 8s before delivering, so
   if 2-3 more land in that same window, the first thing you see is an accurate count
   ("3 open") instead of "1 open" with more trickling in right after. Nothing is lost
   either way — this only affects what the first notification says, not what you
   eventually see.
8. The person answers one question at a time, same as today, using full detail fetched
   just before each one is asked — not all of it loaded up front.
9. Whiska finds the right branch's pane and sends the answer there.

## Rules for mice: written vs. actually enforced

A line in `CLAUDE.md` is a suggestion — works only if the mouse chooses to follow it.
For rules that must never be broken, use a `PreToolUse` hook instead — runs before a
tool call, can actually block it. Two rules:

- **Block edits outside a mouse's own worktree.**
- **Block pushing without approval.** A blocked push becomes a normal question
  ("mouse wants to push branch X — approve?"), through the same question/answer system
  as everything else — not a separate bespoke approval flow.
- **Block direct edits in the main checkout itself, by the main session or anything it
  spawns.** Surfaced by a real firstmate incident: their primary once ran work through
  Claude Code's own subagent tool instead of a real spawned worker, and that work had
  "no durable fleet record" and bypassed every one of their guards. Same risk here —
  every protection in this spec (worktree containment, `checks.yml`, diff review, push
  approval) only covers a mouse's own worktree. An edit made directly in the main
  checkout skips all of it. Carved out: Whiska's own config files (`checks.yml`,
  `dispatch.yml`, the `CLAUDE.md` block) stay editable directly — meta/setup, not
  project code, and blocking those would make basic setup painfully indirect.

**Push detection specifically goes through `PreToolUse`, not a real git `pre-push`
hook — researched, and git hooks lose on both counts:** `git push --no-verify` skips
them outright, so they're convenience, not enforcement; and there are real, currently
open bugs in Claude Code itself around worktrees silently breaking or redirecting
`core.hooksPath` (github.com/anthropics/claude-code issues #66993, #88747) — a real
landmine given Whiska is worktree-heavy. Detecting a push inside an arbitrary bash
string is still imperfect, so err broad: match anything push-shaped and ask, rather
than risk missing a real one. A false "are you sure?" costs nothing; a missed real
push does.

**A real git `pre-push` hook as a second, weaker layer on top — not instead of
`PreToolUse`.** It's skippable (`--no-verify`), so it's not real enforcement on its
own, but it's a cheap extra net: catches anything that reaches `git push` without going
through Claude Code's own tool-call path at all, which `PreToolUse` by definition can't
see. Belt and suspenders, not a replacement.

**Cleanup checked mechanically, not left to a skill's prose.** "Never tear down
unlanded work" (see CLAUDE.md section below) is enforced by `whiska`'s own cleanup
command, which checks whether a branch's work is actually merged before removing
anything, and refuses without an explicit override — same reasoning as the push rule:
a real check beats trusting a skill to remember.

## Review before a push — agnostic, no specific tool required

"Is this worktree actually done?" isn't answered by asking the mouse — it's verified
mechanically, the same way edit/push rules are enforced rather than just written down.
A mouse marking itself `done` is just its own opinion; what actually decides is whether
a small set of repo-defined checks pass.

**Checks come from a small per-repo config file, not a specific tool.** `whiska init`
scaffolds something like `.whiska/checks.yml` — a flat list of named shell commands
(`test: mix test`, `lint: mix credo`, whatever the project actually runs today). The
person writes it, same as `CLAUDE.md`'s block. No-mistakes, a bare `npm test`, a
Makefile target — all become one line here; none of it is hardcoded into Whiska. Empty
or missing file = no checks configured, Whiska only does its existing edit/push
enforcement and nothing more — this is what keeps a repo not using any gate tool today
working with zero friction.

**All configured checks run in parallel**, since they're independent commands with no
ordering dependency — a file with six checks costs about as long as the slowest one, not
the sum of all six. Whiska reports exactly which ones failed, with their output, not
just a pass/fail blob.

**`PreToolUse` never blocks-and-waits — it always denies immediately, every time, no
exceptions.** A hook has to answer fast; it can't stay open while a test suite runs, and
it definitely can't stay open while a human decides. So the instant a mouse tries to
push, `PreToolUse` denies that exact attempt on the spot, with "hold on, checking" as the
tool's result — the mouse's original attempt is dead, not paused. Everything that
happens after that (checks, then approval, then the real push) runs asynchronously, off
to the side, through the same delivery machinery questions already use — never inside
the hook itself.

**What happens in that background work, concretely:**
1. Checks run (`checks.yml`, in parallel — a file with six checks costs about as long as
   the slowest one, not the sum of all six).
2. **Fail** → the failure becomes a message delivered back into the mouse's own pane —
   same shape as any other failing command it already knows how to react to mid-task, not
   the original tool call's result (that's long gone). Bounded escalation: two failures
   in a row on the same push attempt → the next one becomes a real question to you
   instead of another silent retry, carrying the same failure output so you're not
   starting cold. Counter resets on a successful push or once you resolve an escalated
   question.
3. **Pass (or nothing configured)** → Whiska computes a one-line diff stat
   (`3 files changed, +42/-8` — a `git diff --stat` call already available here, costs
   nothing to add) and creates a push-approval question, delivered to you through the
   normal queue.
4. **You answer** — `whiska reply <id> yes` → **Whiska runs `git push` itself, directly,
   in that worktree.** Mechanical, no reasoning needed, same pattern as the (parked)
   PR-merge design ("yes → Whiska runs `gh pr merge` itself"). This doesn't depend on the
   mouse's pane being free or idle at whatever moment you actually get around to
   answering — could be minutes later, could be longer.

Example `.whiska/checks.yml`:

```yaml
# One line per check. Name: shell command. Runs in the worktree root.
# All checks run in parallel. Empty/missing file = no checks, Whiska only
# does its edit/push enforcement.

test: mix test
lint: mix credo --strict
typecheck: mix dialyzer
# review: no-mistakes check --diff   # plug in a review tool later — just another line
```

**Environment/secrets a mouse's checks run with — plain inheritance, stated honestly.**
A mouse (and its `checks.yml` commands) just get normal ambient environment inheritance,
same as any child process — nothing special built, nothing to configure by default.
No secret scanning or redaction of what a mouse commits, logs, or reports back — same
honest limit firstmate itself has. If this ever becomes a real problem, that's a
concrete feature to add then, not something worth guessing at and building now.

## Verifying a push — you are the review, made frictionless

Automated diff review (a model reading the change and judging it, not just running
commands) is deliberately **not built for the MVP.** Real review is a meaningfully
bigger piece of work than anything else in this spec so far, and firstmate itself
doesn't automate this part either — its Captain sees hold *state*, not a diff, and
reads code manually if they want to. So Whiska matches that shape rather than inventing
something bigger: the human is the actual review, same as reviewing any PR — what
Whiska does is remove the friction of getting to the diff.

Every push-approval question includes `whiska diff <id>` as its next step. That command
respects `git config diff.tool` — if you have one configured (VS Code, Beyond Compare,
opendiff, anything), it opens there via `git difftool`; if not, it prints a plain
`git diff` straight to the terminal. No separate Whiska setting for this — git already
has a well-established, pluggable answer to "which diff tool," so Whiska just defers to
whatever you've already told git you prefer. `--tool` / `--no-tool` override the
default for a one-off.

What actually protects you without an automated reviewer, concretely:
- Every push is a real decision you make, not a rubber stamp — with a diff-stat scope
  check and a one-command path to the full diff right there.
- `PreToolUse` physically confines a mouse's edits to its own worktree.
- `checks.yml` catches anything mechanical before a push is even offered to you.
- If PR mode is on later, CI is a second layer outside the mouse's own environment.
- `whiska cleanup` mechanically checks a branch is actually merged before removing it.

If a real automated review tool gets adopted later, it slots into `checks.yml` as one
more line — no new mechanism needed, Whiska stays exactly as dumb as it is today.

## Knowing what a mouse is doing

Rode along on a hook that already exists — no new capture mechanism needed. The
`PreToolUse` hook already sends Whiska every tool call, for the edit/push enforcement
above. That same message now also carries the tool name and its target (file path for
`Edit`/`Write`/`Read`, the command string for `Bash`).

Whiska keeps the *last* one per mouse in memory only — a GenServer/ETS value, not a
`SQLite` row. It's disposable "what's happening right now" state, not history worth
keeping — losing it on a restart is fine, unlike a `Question`. Turned into a short
phrase for display: "editing auth.ex", "running mix test", "reading spec.md". No tool
call for a while → "idle".

This also replaces the earlier plan to read each pane's visible screen content directly
— that would've needed a separate, unverified code path just for this. The hook data is
already flowing for enforcement, so this is free.

## Install and setup

1. **Installing Whiska itself** — packaged like `herdr`/`glow` (`brew install whiska`),
   self-contained, no Elixir needed on the user's machine. Runs as a background service
   under `launchd`, via `brew services` — same supervisor as anything else installed
   that way, so a crash gets auto-restarted without Whiska needing to build its own
   supervision. A mouse crashing is covered by the orphan sweep; this is the matching
   answer for Whiska itself crashing — without it, every mouse would silently lose its
   route to you until someone noticed and restarted it by hand.
2. **Turning it on for a project — per-project, not global.** `whiska init` writes the
   repo's own `.claude/settings.json`, checked into git. Anyone who clones the repo and
   has Whiska installed gets the same rules automatically.

Chosen over global hooks on purpose: global means zero setup per project, but rules
wouldn't travel with a shared repo. Per-project keeps the repo the source of truth for
its own rules.

## CLAUDE.md — where judgment actually lives

Whiska stays dumb on purpose (routing and storage, no reasoning). All real judgment —
priority, what's worth escalating, what a mouse should and shouldn't do — lives in
plain-English rules the mice actually read, same as firstmate's `AGENTS.md`: a short
list of hard rules that never bend, plus written principles for everything else. No
scoring system, no algorithm — just good instructions and a capable model.

`whiska init` writes a clearly marked block into the project's own `CLAUDE.md`
(created if missing):

```
<!-- whiska:start -->
...Whiska's rules here...
<!-- whiska:end -->
```

`whiska update` finds that block and replaces it with whatever the current version
ships — never touches anything else in the file. Whiska's release carries its own
template; upgrading Whiska (`brew upgrade`) doesn't touch any project automatically,
you opt in per project by running `whiska update` there.

Default template borrows from firstmate's real hard rules and principles, adapted:

- **Never tear down unlanded work** — don't `git worktree remove --force` or discard a
  mouse's uncommitted work without the human explicitly saying to.
- **Report outcomes faithfully** — a mouse says plainly when something failed, with
  the evidence, not a softened version.
- **Evidence-first when asking for a decision, in one concrete shape — not just the
  principle, the actual template:**
  1. One line naming the real tension — not a vague "need input," the actual fork.
  2. What each option actually implies, plainly — not just labels.
  3. A stated recommendation — never leave it to the human to guess which way you lean.
  4. The exact words that answer it — never trail off and hope the human infers what
     to say back.

  (This repo's global CLAUDE.md already does this for the human-facing side; the
  mouse-facing block should hold the same standard talking to the main session, and the
  main session should hold it too when relaying one of Whiska's own questions to the
  human — the shape doesn't change depending on who's asking.)
- **Durable state over memory** — a mouse should trust what's actually in the repo /
  what Whiska has recorded over its own recollection of the conversation so far.
- **Check git state before assuming a blank slate** — `git log`/`git status`/`git diff`
  before doing anything, any time a worktree already has history. Not special-cased for
  `whiska reopen` — a standing habit for every mouse, since it's just as useful
  whenever picking up on existing work as it is after an orphaned pane. This is what
  makes `whiska reopen` itself simple: it just delivers the saved question as the first
  message, nothing more — the git-check behavior is already there by default.
- **Use subagents freely inside your own worktree** — breaking your own investigation
  or sub-tasks into a few parallel lookups is normal, expected, and needs no special
  handling from Whiska; it never leaves your own worktree, so none of Whiska's rules
  even apply to it. This only ever concerns a mouse's *own* work, never the main
  session — see its own rule above about never touching subagents at all.
- **A finding isn't a green light.** A sniff mouse's report is evidence for a decision,
  not the decision itself — implementing what it found still needs its own separate
  approval, same as any other push.
- **Investigate rigorously, not just fast.** Don't assume the most recent change is the
  cause just because it's recent. Before settling on a theory, actually look for
  evidence that would prove it wrong. Keep "what caused it," "what hid it," and "what
  the human actually saw" as three separate facts, not one blurred story.
- **Scope creep gets surfaced, not folded in silently.** A fix needed to keep
  already-agreed behavior correct stays in scope even if it touches files nobody named
  at the start. A fix that adds a new guarantee, subsystem, or abstraction is scope
  *expansion* — that becomes its own question, never something quietly bundled into the
  current push.
- **One approval doesn't carry over.** Being told yes once — an edit-outside-worktree
  override, a push exception — doesn't mean yes again for something similar later. Ask
  again each time rather than assuming precedent.

**One more rule, aimed the other direction — at the main session, not a mouse.** The
same `CLAUDE.md` block reaches every Claude Code session in the repo, main session
included, since it's just a project-level file. Worth a rule specifically for how *your*
session behaves when Whiska delivers a question into it:

- **Present a delivered question faithfully, then wait — never act on the human's
  behalf.** A delivered push-approval question arrives as a normal message in the
  conversation, and a helpful model might be tempted to just go run `whiska diff` itself,
  or worse, guess at an answer instead of waiting. Don't. Show the diff stat and how to
  see more, then stop — answering is always the human's move, never something to do for
  them because it seemed obvious.

## Statusline

`whiska init` also adds a project-level `statusLine` entry, showing how many mice are
currently alive and how many questions are open for that repo (e.g. `🐭×3 · 🐱 2 open`),
refreshed each time Claude Code calls it — no push from Whiska, just a quick check each
time it's asked.

**Exactly one mouse alive → show its excerpt instead of the count.** One line has room
for one real phrase (e.g. `🐭 editing auth.ex`), pulled from the last-tool-call state
described in "Knowing what a mouse is doing" above. At two or more mice, a real excerpt
per mouse doesn't fit a single terminal line without truncating into noise — falls back
to the plain count, and `whiska mice` is where you'd look for each mouse's own excerpt,
one per line, no width fight.

Project-level `statusLine` replaces the global one, it doesn't merge with it — so the
script `whiska init` installs calls the user's existing global statusline first, then
appends the open-question count to its output. Nothing existing gets lost.

## Seeing across every project — one owl, not a blind spot

A per-repo statusline only ever shows what's happening in the repo you're literally
sitting in. Given several projects get worked at once, each with its own history of
losing the thread between them, "check the one repo you're in" isn't the whole picture
— something could be waiting on you in a different project's main session while you're
looking at this one.

Because there's one owl for the whole machine (see "What's new" above), this is
nearly free to answer — it already holds every active repo's state in memory, so
"what's open anywhere" is one more query, not a new process talking to other processes.

- **The statusline adds what's elsewhere, named when there's exactly one** — same
  "single case gets detail, several fall back to a count" rule already used for the
  mouse excerpt. One open thing elsewhere → name the project:
  `🐭×3 · 🐱 2 open · ⚡ api-service`. Several → a plain count, with `whiska projects` as
  where you'd go for the actual breakdown — a bare number with no name attached isn't
  something you can act on.
- **`whiska projects`** lists every active repo with its mouse/question counts, run
  from anywhere on the machine (see command list above).
- **`whiska goto <project>`** actually jumps your terminal to that project's main
  session pane, for when you want the full context rather than a blind reply.
- This needs one more thing under the hood: a **second, separate socket** at a fixed
  machine-level location (e.g. `~/.whiska/owl.sock`), distinct from each repo's own
  private socket. The per-repo sockets stay exactly as hardened as designed (push
  approval, mouse identity, the peer-PID check) — this one only ever answers read-only
  "what's open, where," never anything that can approve a push or act on a mouse, so it
  doesn't need that same hardening — normal Unix file permissions (only your own user
  can read it) are enough.

**A light animation while mice are working.** No push from Whiska, no risky hook into
Claude Code's internals (firstmate does this via an undocumented drawing API — not
worth the fragility). Just pick a different frame each time the statusline redraws,
based on the clock — same idea as a plain terminal spinner, e.g. `🐭` → `🐭·` → `🐭··`
cycling by the current second. Only animates while at least one mouse is actually
working; sits still when idle. How smooth it looks depends on how often Claude Code
calls the statusline script — not confirmed, worth checking once this gets built.

## Rollout

Runs **alongside** today's bash wake-queue system for a while, not a hard cutover.
Whiska controls real things (edits, pushes) — proving it out with the current system
still in place as a fallback is safer than switching all at once.

## Repo

Stayed as this spec, in dotfiles' `.scratch/whiska/`, until the design was solid enough
to start writing real code. That point is now — a separate `whiska` repo, gitignoring a
`worktrees/` folder the same way this repo does, holds the actual code from here on.
This spec stays behind in dotfiles as the design record; it isn't copied into the new
repo.

## v0.0.1 — the first real slice

The smallest real, end-to-end piece: no owl, no cross-repo visibility, no
`checks.yml`. Just enough to prove the core plumbing — identity, storage, one enforced
rule — actually works.

**Shape:** a plain CLI (`mix escript.build`, a `whiska` binary), not a long-running
process. The `PreToolUse` hook invokes it fresh on every tool call; it opens the SQLite
file, makes its one decision, exits. No supervision tree yet — that arrives with the
owl, in a later slice.

**Identity:** `mouse_id` is minted lazily, on the first hook invocation inside a
worktree that has no marker file yet. The CLI writes the marker file itself at that
point — nothing upstream (`spawn-worktree`, etc.) needs to change for this slice.

**Storage:** real `Ecto.Migration` + SQLite, the same tech the eventual owl uses,
just opened per-invocation instead of held open by a long-lived process. Both tables
exist with their real schema from the start, so nothing about them changes shape when
the owl arrives later:

- `Mouse`: `mouse_id` (PK), `pane`, `path`, `branch`, `mode`, `created_at`. `mode` is
  stored but **not yet read** by any v0.1 logic — see the sniff-mode note below.
- `Question`: exists with its real schema; v0.1 has nothing that needs to write a
  meaningful row into it yet, since its one rule denies rather than asks.

**The one enforced rule:** deny any tool call whose target path resolves to the main
checkout rather than the current worktree. Detected by comparing the tool's target path
against the known main-checkout path — not git internals (`git worktree list`, `.git`
file-vs-directory checks) — since Whiska already knows that path from how
`spawn-worktree` lays worktrees out under `worktrees/<branch>/`.

**Explicitly deferred, not forgotten:** sniff-mode read-only enforcement (deny
`Edit`/`Write`/mutating `Bash` when `mode: sniff`) uses this exact same hook and exact
same decision point — trivial to add once this slice lands. Left out of v0.1 on
purpose, so the first pass proves the plumbing with the simplest possible rule instead
of also getting mode-awareness right on day one. Next slice's job, not this one's.

**Out of scope for this slice, staying out on purpose:** the owl and its supervision
tree, cross-repo visibility (`whiska projects`/`goto`), `checks.yml`, push
approval/`PreToolUse`-denies-then-async-approves flow, the herdr/Mox behaviour
boundary (nothing in v0.1 talks to herdr).

## Staying alive: dead mice and stuck mice are different problems

Two failure modes, only one of which the sweep can see. **Dead** — the pane itself is
gone (closed, crashed) — is what the periodic sweep below catches, since "does the pane
exist" is a clean yes/no. **Stuck** — the pane is alive, Claude Code is running, but
nothing is actually progressing (looping on the same failed approach, working on a
misunderstood task, just gone quiet for a long stretch) — is invisible to that same
check, since the pane genuinely does exist. Both need covering; neither is the other.

### Dead mice

Checked by the same mechanism as restart recovery: does the pane a `Mouse` row points at
still actually exist?

- **Periodic sweep**, every few minutes, since Whiska's already a long-running
  program — walk `Mouse` rows (once per mouse, not once per question — several
  questions can share one dead pane, no reason to ask herdr the same thing twice), ask
  herdr if each one's pane is still alive.
- **The same sweep runs once, immediately, on startup** — covers the "Whiska restarted,
  are the saved panes still real" case for free, no separate mechanism needed.

**What actually happens when a pane turns up dead, step by step** (this used to be
scattered across a few sections — written out here as the one place to read the whole
sequence):

1. The sweep finds a `Mouse` row whose pane is gone.
2. That row is marked dead — **not deleted.** Every one of its still-open questions
   cascades to `orphaned` at the same time, instead of sitting "open" forever.
3. It drops out of `whiska mice` (alive-only listing) and out of the statusline count —
   a dead mouse doesn't count as a live one.
4. **The worktree folder itself is untouched** — nothing here ever deletes anything from
   disk, only marks state in the database.
5. `whiska reopen <branch>` reads the marker file already sitting in that folder (same
   `mouse_id` as before — a file on disk, unaffected by the pane dying), starts a fresh
   pane, and **updates that same row's `pane` column** rather than creating a new mouse.
   Its question history comes along automatically, since it was always keyed by
   `mouse_id`, never by the pane.
6. The row only actually disappears for good via `whiska cleanup` — which is a
   deliberate, guarded, human-triggered action (checks the branch is actually merged,
   refuses without an override), never something the sweep does on its own. And even
   then, per "Answered questions are kept forever" below, the row itself still isn't
   deleted — same small-and-cheap reasoning as `Question`, just permanently inert
   afterward.

**Getting the pane back is easy — the worktree folder is still on disk.** A fresh
pane pointed at that same folder starts fine. **Getting the exact conversation back
is not confirmed** — a brand-new Claude Code session has no memory of the old one
unless Claude Code's own session-resume feature works through herdr. Worth verifying
before promising it, not assumed.

### Stuck mice

**Detection reuses a signal that already exists — no new capture mechanism.** The
last-tool-call excerpt from "Knowing what a mouse is doing" is a reasonable proxy: if it
hasn't changed in a long while, and there's no open question waiting on you (so it's not
simply waiting on an answer), that's worth the main session taking a look.

**The ladder, in order — cheap fixes tried before bothering you, same philosophy as the
bounded-retry pattern already built for failed checks:**

1. **Check its own unanswered questions first.** Maybe it's not stuck at all — maybe a
   question got delayed in delivery. Rule that out before assuming anything's broken.
2. **Re-state existing instructions, never a new decision.** If the confusion is about
   something you already told the main session earlier in this same conversation,
   pointing back at it isn't a new call — you already made it, this just relays it
   again. If the confusion isn't something you already answered, this rung doesn't
   apply — skip straight to a corrective nudge, or if it's a genuine decision, that's a
   normal question to you, same as everything else in this spec. The main session never
   infers, extrapolates, or decides something new here.
3. **One corrective nudge.** A single message into the mouse's pane — "you're stuck on
   X, try Y" — one shot, not an ongoing back-and-forth.
4. **Relaunch**, same as `whiska reopen` — a fresh session against the same worktree.
   Uncommitted work is safe regardless (it's just files on disk), but being deliberate
   about it here matters.
5. **Escalate to you only after a second relaunch still fails.** Not the first sign of
   trouble — two real attempts to self-correct before it becomes your problem.

## Testing Whiska itself

Standard, current Elixir practice, not a shortcut: define a small formal contract
("behaviour") for "talking to herdr," a real implementation for production, a fake one
for tests (via `Mox`) — mocking confined to that one boundary only. Everything else
(the actual question-routing, queueing, classification logic) is plain code, tested for
real, no mocking needed.

## Not building yet

Auto-reminders for unanswered questions, sending updates to other places (phone, a web
page), push notifications when no session is open, Whiska running Claude Code directly
instead of through herdr (mice stay visible in herdr, on purpose).

## Still needs deciding

**Endpoint identity, designed — two layers.**

1. **Cheap, first-pass check:** a request must present the actual marker-file content,
   not just claim an id — Whiska cross-checks the claimed working directory against the
   path it recorded when that id was created, rejects a mismatch.
2. **Real backstop: kernel-level peer identity, not the payload's word for it.**
   Whiska's local endpoint is a Unix domain socket, not a plain network port. macOS lets
   the *listening* side of such a socket ask the kernel exactly which real process (PID)
   is on the other end — confirmed via `LOCAL_PEERPID`, usable from Elixir/OTP today.
   That PID can't be faked by the connecting process, unlike anything in the request
   body. Whiska walks that PID's real parent chain (`ps -o ppid=`) to confirm it's
   actually a descendant of the legitimate `claude` process for that worktree — not
   just something that read a marker file it happened to find.

Honest limit, even with both layers: doesn't stop a truly determined co-resident
process willing to go to real lengths — everything still runs as the same OS user, no
sandboxing. Real airtight protection would need OS-level isolation, out of scope. This
stops accidental/casual spoofing and anything short of a deliberately sophisticated
attack, which is a real, meaningful bar, not a token one.

**Two `whiska start` for the same repo:** `whiska start` first checks whether this
repo's instance is already running and already has a main session registered (via its
local socket under `.git/whiska/`). If so, refuse and name the pane that already holds
it, with an explicit override to deliberately switch which pane is main.

**`whiska stop` (per-repo shutdown):** decided — see the command list above and "What's
new." Shuts this repo's house inside the owl, leaving the house itself intact; the owl
keeps running for every other repo.

**PR opening and merge tracking — designed, not committed.** You're 50/50 on how often
these worktree branches actually go through a PR, so this isn't built for the MVP, but
the shape is worked out for whenever it's wanted:

- Opt-in per repo, a `pr: true` line alongside `checks.yml` — off by default, matches
  today's spec (stop at push, you handle PRs/merges yourself).
- When on: after push succeeds, Whiska tells the mouse to open the PR itself (it has the
  context to write a real title/summary; Whiska stays dumb on purpose). Whiska doesn't
  trust the mouse's self-report though — it confirms the PR exists by asking GitHub
  directly (`gh pr list --head <branch>`), same "verify mechanically, don't trust the
  model's word" principle as everything else here.
- The existing periodic sweep (already polling for dead panes) gets one more job for
  branches with an open PR: check `gh pr view --json mergeable,statusCheckRollup` until
  it's actually green.
- Once green, it's a normal question — "PR #42 is green and mergeable — merge it?" —
  same question/answer path as push approval. Yes → Whiska runs `gh pr merge` itself,
  purely mechanical.

**Storage: SQLite, kept on purpose, not swapped for plain files.** Considered going
back to flat files to sidestep schema migrations, but migrations in Elixir specifically
are a mature, well-worn feature (`Ecto.Migration`), not something risky being pioneered
here. Flat files would undo something this design already moved away from deliberately
— real queries, no hand-rolled locking, no directory scanning.

## Where this came from

- `docs/research/agent-orchestration-relay-comparison.md` (this repo)
- `raw.githubusercontent.com/kunchenguid/firstmate/main/README.md`
- `bin/herdr-worktree-wake.sh`, `claude/hooks/herdr-worktree-notify.sh`, `claude/CLAUDE.md`
