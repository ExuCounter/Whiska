---
name: spawn-worktree
description: "Spawn a new git worktree under worktrees/<branch> as a herdr workspace and start a mouse — a Claude Code session — inside it, without switching the person's view. Use when the person asks to start a new task in a worktree, spawn a worktree, or fork off into a fresh workspace. Requires HERDR_ENV=1 and a git repo."
---

# spawn-worktree

Create a git worktree at `worktrees/<branch-name>` under the repo root, open it as a herdr
workspace without stealing focus, and start a mouse in it — handing it the task when there
is one. Leave Claude unstarted only when the person explicitly says so.

## 1. Preconditions

```bash
test "${HERDR_ENV:-}" = 1
test -n "${HERDR_WORKSPACE_ID:-}"
git rev-parse --is-inside-work-tree
```

Any check fails → say what is missing and stop. Plain `git worktree add` is no fallback:
the herdr workspace is the point of this skill.

## 2. The branch name

Get it from the person: `feat/<slug>`, `fix/<slug>`, or whatever convention the repo uses
— `git branch --show-current` and recent branches hint at it. A name you suggest is said
out loud, never picked silently. Building what an
investigation proposed is the one exception: that section, below, names the branch
itself.

## 3. Create the worktree, from the repo root

`herdr worktree create` picks the repo from the calling directory, not from `--workspace`,
so run from anywhere else — a subdirectory, another repo's worktree — it silently makes
the worktree in the wrong place:

```bash
repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"
```

```bash
herdr worktree create \
  --workspace "$HERDR_WORKSPACE_ID" \
  --branch <branch-name> \
  --label <branch-name> \
  --path worktrees/<branch-name> \
  --no-focus
```

- `--path worktrees/<branch-name>` is fixed: Whiska derives a mouse's worktree root and its
  main checkout from exactly this layout (`Whiska.Layout`). Changing it means changing
  Whiska. `/worktrees/` is excluded globally via `core.excludesFile`, so it needs no
  per-repo `.gitignore` entry.
- `--no-focus` leaves the person's current view untouched.
- Leave `--base` off and herdr starts from the current HEAD. A hardcoded `origin/HEAD` or
  `main` fails with `invalid reference` in the many repos without it. Add `--base <ref>`
  only when the person names a starting point ("branch from main", "branch from
  origin/develop"), once `git rev-parse --verify <ref>` passes.

From the JSON response take `.result.workspace.workspace_id` (the new workspace) and
`.result.root_pane.pane_id` (its root pane). Either missing → stop and report the raw
response; never guess an id.

## 4. Carry Whiska's hooks in

Before Claude starts: Claude Code loads hooks at startup. A worktree holds only committed
files, so where the repo's `.claude/` was never committed the worktree has no `Stop` hook —
its mouse never leaves anything on the doorstep, and the owl never sees it finish or ask.

```bash
if [ -f .claude/hooks/whiska.sh ] && [ ! -f worktrees/<branch-name>/.claude/settings.json ]; then
  mkdir -p worktrees/<branch-name>/.claude
  cp -R .claude/hooks .claude/settings.json worktrees/<branch-name>/.claude/
fi
```

The hooks and `settings.json`, nothing else. Never `settings.local.json` (this machine's
local overrides), and never `.claude/skills`: the skills are main-session tools (read a
delivered line, reply, spawn), a mouse speaks through its Stop hook alone, and the
person's own skills live in `~/.claude/skills`, which Claude Code reads in every
directory. The copy is untracked and goes with the worktree. The `if` skips it, silently, when the
worktree already has `settings.json` or the main checkout has no Whiska.

## 5. Choose the mouse's shape

A shape is a mode, a model and an effort, each chosen on its own. The rules for all three
ship inside Whiska; read them first, from anywhere:

```bash
whiska shape --rules
```

It prints JSON. Choose from it, against the request:

- **Mode** — `modes` says what the request has to be, for build and for sniff. A sniff
  mouse may not write anything; Whiska enforces that, not this choice. Unclear → ask the
  person which. A request that reads as investigation is never build by default.
- **Model** and **effort** — `model.choose` and `effort.choose` are ordered lists. Walk
  each from the top and take the first rule whose `when` fits the request; the last rule
  is the catch-all. Choose each apart from the mode and from the other: a hard
  investigation can be sniff on the heaviest model at the highest effort.
- The person named a model or an effort → use theirs, no rules.

Pass what you chose as `--model <use>` and `--effort <use>`. Leave a flag off when its
catch-all matched: `whiska shape` applies that one itself, a null one included, which
means the person's own default. `whiska shape` checks only that each is one plain word;
Claude Code decides which models exist.

## 6. Shape and start the mouse, in one command

One Bash call: a shell variable does not survive into the next one, and a split start
runs every mouse with no flags at all. The person said "don't start Claude" or the like →
run the `whiska shape` line alone.

```bash
flags="$(cd "worktrees/<branch-name>" >/dev/null && whiska shape <build|sniff> <your --model and --effort, if any>)" || { echo "shape failed - Claude not started"; exit 1; }
case "$flags" in *[!a-z0-9\ ,-]*) echo "whiska shape printed more than flags - Claude not started"; exit 1;; esac
eval "set -- $flags"
if [ $# -gt 0 ]; then
  herdr agent start <agent-name> --kind claude --pane <root-pane-id> --timeout 15000 -- "$@"
else
  herdr agent start <agent-name> --kind claude --pane <root-pane-id> --timeout 15000
fi
```

- `whiska shape` records the shape in Whiska before Claude exists, so the mouse's very
  first tool call is already judged by its mode. It prints the flags to start Claude with —
  the model, the effort, and the fallback chain Claude Code walks itself when a model is
  overloaded or not available — or nothing.
- It prints only plain words (letters, digits, `-` and `,`). The `case` line refuses
  anything else that reached `$flags` — a shell hook that prints on `cd`, say — so `eval`
  only splits words into arguments, the same in bash and zsh.
- On stderr it says what it recorded. Keep that line: it goes in the report.
- **It fails → the command stops before Claude starts. Report the error and
  do not start Claude by hand:** a mouse started without its shape may not write anything
  until the person runs `whiska mode` in its worktree, so it would stall at its first
  edit.
- `<agent-name>` is the branch name in herdr's terms: lowercase letters, digits, `-` and
  `_`, starting with a letter, at most 32 characters — `feat/csv-data-page` becomes
  `feat-csv-data-page`. herdr refuses a `/`.
- `agent start` polls for shell readiness itself, so run it straight away, with no sleep.
  Everything after `--` reaches `claude` as it is.
- The response's `.result.argv` must end in exactly the words `whiska shape` printed. It
  does not → say so in the report.

## 7. Hand off the task

A worktree spawned for a task — a feature, a fix — gets it now, so the person retypes
nothing:

```bash
herdr agent prompt <root-pane-id> "<the task, in the person's own words>"
```

The task as the person described it, at full detail. A bare "spawn me a worktree" has no
task: skip this step.

## Building what an investigation proposed

The `whiska-delivered` skill sends you here with a question id when the person picked
"Build what it proposes" on a finished sniff mouse's report. That pick was their yes to
the proposal, and everything else comes from it: ask the person nothing.

A mouse wrote the proposal, and this session's shell runs whatever reaches a command line.
So no character of it goes on one: the branch is a name you make, and the task carries
only the question id.

- **Branch** — your own short name for what the Build line describes, in this repo's
  convention (`feat/<slug>`, `fix/<slug>`), made of `a-z0-9`, `-` and `/` only and never
  copied from the proposal. The report shows it.
- **Shape** — chosen as in step 5, but judged against the Build and Touches lines, not
  against the request the investigation began from: the work is described now, and the
  rules weigh that.
- **Task** — one line, so it is typed as one prompt. The whole report is already in
  Whiska, so it travels by its id:

  ```bash
  herdr agent prompt <root-pane-id> 'Build the Proposed build in question #<id>. Read it first with: whiska show <id> - its Build line is the brief, the rest is what the investigation found.'
  ```
- **Report** — one line, in place of step 8's: the branch, then what `whiska shape` said on
  stderr in plain words — "A fresh session is building it on <branch>: it can change
  files, on <model> at <effort> effort."
- Leave the investigation's worktree as it is: it has nothing to merge, and the person may
  still want to talk to it.

## 8. Report

One line: "Created worktree <branch> at worktrees/<branch>, a Claude session is working
on it there.", then what the line `whiska shape` printed on stderr says, in plain words —
"it can only look, not change files" for sniff, "it can change files" for build, then the
model and the effort that line names.
Restate that line, not what this skill meant to set, so a shape that went wrong shows up
here. Say that it will not interrupt them and
that Whiska delivers its question when it has one. Then stop: the task is the mouse's,
and none of it happens in this session.

Its questions reach the main session through Whiska once this repo is `whiska init`-ed and
the owl is running (`whiska doctor` checks both): every turn there ends with a status
marker, the owl delivers a one-line pointer, and `whiska show <id>` shows the whole
message. Read it there, never from the pane: Claude Code runs on the alternate screen, so
`herdr pane read` returns a truncated tail.
