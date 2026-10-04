---
name: spawn-worktree
description: "Spawn a new git worktree under worktrees/<branch> as a herdr workspace and start a mouse — a Claude Code session — inside it, without switching the person's view. Use when the person asks to start a new task in a worktree, spawn a worktree, or fork off into a fresh workspace. Requires HERDR_ENV=1 and a git repo."
---

# spawn-worktree

Create a git worktree under `worktrees/<branch-name>` in the repo root, open it as a
herdr workspace without stealing focus, and start a mouse inside it. The default is all
three steps — do not skip the Claude start unless the person explicitly says so.

Installed by `whiska init` (Whiska ADR-0046). Whiska owns the protocol between herdr,
Whiska and Claude, so the skill that creates a mouse ships with the thing that then
tracks it.

## Preconditions

Before anything else, verify:

```bash
test "${HERDR_ENV:-}" = 1
test -n "${HERDR_WORKSPACE_ID:-}"
git rev-parse --is-inside-work-tree
```

If any check fails, say what is missing and stop. Do not fall back to `git worktree
add` — the herdr integration is the whole point of this skill.

## Ask for the branch name

Get the branch name from the person. Use `feat/<slug>`, `fix/<slug>`, or whatever
convention the repo uses; check `git branch --show-current` and recent branches for
hints. Do not invent a branch name silently.

## Create the worktree

Run it **from the repo root**. `herdr worktree create` picks which repo to work on from
the calling directory, not from `--workspace`, so running it from anywhere else — a
subdirectory, or another repo's worktree — silently makes the worktree in the wrong
place:

```bash
repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"
```

`/worktrees/` is excluded globally via `core.excludesFile`, so it needs no per-repo
`.gitignore` entry.

Do NOT pass `--base` by default. Many repos do not have `origin/HEAD` set, and
hardcoding a base ref like `origin/HEAD` or `main` fails with `invalid reference`. Let
herdr resolve the default (current HEAD). Only add `--base <ref>` if the person names a
starting point ("branch from main", "branch from origin/develop"), and verify it first
with `git rev-parse --verify <ref>`.

`--path` is relative to the repo root and `--no-focus` leaves the person's current view
untouched. `--path worktrees/<branch-name>` is load-bearing beyond herdr: Whiska derives
a mouse's worktree root and its main checkout from exactly this layout (Whiska ADR-0030,
`Whiska.Layout`). Do not change it without changing Whiska.

```bash
herdr worktree create \
  --workspace "$HERDR_WORKSPACE_ID" \
  --branch <branch-name> \
  --label <branch-name> \
  --path worktrees/<branch-name> \
  --no-focus
```

Capture the JSON response. You need:

- `.result.workspace.workspace_id` → the new workspace id
- `.result.root_pane.pane_id` → the root pane in that workspace

If either field is missing, stop and report the raw response. Do not guess ids.

## Carry Whiska's hooks in — before Claude starts

A worktree only contains committed files. When the repo's `.claude/` folder is not
committed (a repo where `whiska init` was run but the folder was never added), the new
worktree has no `Stop` hook, so the mouse there never leaves anything on the doorstep
and the owl never sees it finish or ask anything. Claude Code loads hooks at startup, so
this has to happen before `agent start`, not after.

If the main checkout has `.claude/hooks/whiska.sh` and the new worktree has no
`.claude/settings.json`, copy the hooks and the settings over — nothing else. Never
`settings.local.json` (this machine's local overrides), and never `.claude/skills`:
the skills are main-session tools (read a delivered line, reply, spawn), a mouse
speaks through its Stop hook alone, and the person's own skills live in
`~/.claude/skills`, which Claude Code reads in every directory.

```bash
if [ -f .claude/hooks/whiska.sh ] && [ ! -f worktrees/<branch-name>/.claude/settings.json ]; then
  mkdir -p worktrees/<branch-name>/.claude
  cp -R .claude/hooks .claude/settings.json worktrees/<branch-name>/.claude/
fi
```

Skip it silently when the worktree already has a `settings.json` (the folder is
committed there, which is the Whiska ADR-0016 shape) or when the main checkout has no
Whiska. The copy is untracked in the worktree and disappears with it.

## Give the mouse its shape — before Claude starts

A mouse is spawned as one of two shapes (Whiska ADR-0069). **sniff** investigates and
reports: it may not write anything, and it starts on a cheaper model. **build** makes a
real change and keeps the person's own default model. Pick from the request:

- Sniff when the outcome is an answer, not a change: "find out why", "look into",
  "investigate", "how does", "is it safe to", a report or a recommendation.
- Build when the outcome is a change: a feature, a fix, a refactor, docs.
- Unclear → ask the person which. Never default a request that reads as investigation
  to build.

Name a model only if the person named one — `--model <alias>`. `whiska --help` lists
the aliases, and `whiska shape` refuses one it does not know.

## Shape and start the mouse — in one command

Starting Claude is the default. Only skip it if the person said "don't start Claude" or
equivalent; then run the `whiska shape` line alone.

Run this as **one** Bash call. A shell variable does not survive from one call to the
next, so splitting it starts every mouse on the default model:

```bash
model="$(cd "worktrees/<branch-name>" && whiska shape <build|sniff>)" || { echo "shape failed - Claude not started"; exit 1; }
if [ -n "$model" ]; then
  herdr agent start <agent-name> --kind claude --pane <root-pane-id> --timeout 15000 -- --model "$model"
else
  herdr agent start <agent-name> --kind claude --pane <root-pane-id> --timeout 15000
fi
```

`whiska shape` records the mode in Whiska before Claude exists, so the mouse's very
first tool call is already judged by it. It prints the model to start on, or nothing for
the person's own default, and says on stderr what it recorded — keep that line, it goes
in the report. **If it fails, the command stops before Claude starts. Report the error
and do not start Claude by hand:** a mouse started without its shape may not write
anything until the person runs `whiska mode` in its worktree, so it would stall at its
first edit.

`<agent-name>` is the branch name in herdr's terms: lowercase letters, digits, `-` and
`_`, starting with a letter, at most 32 characters — `feat/csv-data-page` becomes
`feat-csv-data-page`. herdr refuses a `/`, so the branch name itself fails for any
slashed branch.

`agent start` polls for shell readiness itself — do not sleep first. Everything after
`--` is passed to `claude` as it is.

The JSON response carries `.result.argv`; for a sniff mouse it must end in `--model`
and the model. If it does not, say so in the report.

## Hand off the task

If this worktree was spawned for a specific task — a feature, a fix, not a bare "spawn
me a worktree" with nothing to do yet — send that task to the new mouse so it starts
work without the person retyping anything:

```bash
herdr agent prompt <root-pane-id> "<the task, in the person's own words>"
```

Write the task the way the person described it; do not summarise it into something
thinner. If there was no specific task, skip this step.

## Checking on it

Questions from this mouse reach the main session through Whiska, once this repo has been
`whiska init`-ed and the owl is running (`whiska doctor` checks both). Every turn there
ends with a worktree-status marker, Whiska delivers a one-line pointer, and
`whiska questions <id>` shows the whole message. Do not read the pane to find out what
it said: Claude Code runs on the alternate screen, so `herdr pane read` returns a
truncated tail.

## Report back

One line: "Created worktree <branch> at worktrees/<branch>, a Claude session is working
on it there.", then what the line `whiska shape` printed on stderr says, in plain words —
"it can only look, not change files" for sniff, "it can change files" for build, then
the model that line names, or "your default model" when it names none.
Restate that line, not what this skill meant to set, so
a shape that went wrong shows up here. Say that it will not interrupt them and that
Whiska delivers its question when it has one. Do not linger, and do not do any of the task yourself in this session —
that is what the mouse is for.
