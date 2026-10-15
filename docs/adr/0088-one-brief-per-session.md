# Each session starts with one brief, on its launch line

Everything Whiska tells a session is one Markdown file, its **brief**, and Claude Code is
started with it: `claude --append-system-prompt-file <brief>`. Three briefs ship in
`priv/briefs/`, read into the escript when it is built.

| Session | Brief | Written to | Put on the launch line by |
| --- | --- | --- | --- |
| Main session | `main.md` | `main.md` in the house, beside its database | `whiska start` (ADR-0066) |
| Build mouse | `build.md` | `.whiska-brief.md` at the worktree root | `whiska spawn`, or `whiska shape`'s flags |
| Sniff mouse | `sniff.md` | the same | the same |

Nothing else carries Whiska's words into a session: no `SessionStart` hook, no skills, no
block in a `CLAUDE.md`, no `keep`. What `whiska init` installs is the shim and three hooks
— `PreToolUse` for the hold (ADR-0011), `Stop` for the doorstep (ADR-0036),
`UserPromptSubmit` for answers (ADR-0080) — and, globally, the person's one-word shell
commands (ADR-0079). The repo's own `CLAUDE.md` loads as Claude Code loads it, and
Whiska writes nothing in it.

A mouse's brief is git-ignored like the spec (ADR-0063), so a branch never carries it. The
main session's lives in the house, so a checkout holds no file of Whiska's. Each brief
names the files `whiska show` links and the end-of-turn markers the owl reads (ADR-0009),
and everything else in it is for the model alone.

## Procedures are commands; judgment stays in the conversation

A procedure a session followed from prose is a command with fixed steps:

| Command | Does |
| --- | --- |
| `whiska spawn build\|sniff <branch> <task-file>` | herdr makes the worktree, the mouse is recorded and shaped (ADR-0069), its brief written, Whiska's hooks carried where the repo never committed them, Claude started with the flags, then the task typed as its first prompt |
| `whiska spawn build <branch> --from <id> [--comments <file>]` | the same, its task fixed text naming the finished question whose What to change it builds (ADR-0074) |
| `whiska send <branch> <file>` | the file copied into the mouse's worktree, and one fixed line pointing at it typed into its pane |
| `whiska land <id> [--commit <file>]` | the branch's own commits copied onto the main checkout's branch, oldest first, then the repo's `checks:` |
| `whiska pr <id> [--commit <file>]` | the branch pushed by its name, a merge request opened with `gh` or `glab`, its link recorded (ADR-0087) |
| `whiska drop <branch> [--force]` | worktree, herdr workspace and branch taken down together, refused while it would lose work |

Which mode, which model and effort, which branch name, whether a task continues a branch
already at work: those are the main session's to judge, with the person, and it passes
each as an argument. The command makes no choice of its own. A missing or unsafe argument
is refused before anything is created. All five are the person's (ADR-0079): a mouse that
runs one is denied.

What a session does once per turn, in its own judgment — grilling, the spec and build
plan, a bug's research document, finishing, a merge request's comments — is a section of
its brief, a few lines each. The cold review is a fresh reviewer the mouse briefs itself,
from the diff, the spec or research document and the decisions as they stood at the
base, never the build plan (ADR-0049).

After a mouse's report the main session prints what `whiska show <id>` prints, as is,
and stops (ADR-0089). The person
says what happens next — "land", "pr", "drop", an answer, a note for the mouse — in their
own words, and the main session runs the command that says. No lettered options are
offered.

## What carries over

- **Judgment is written, hard rules are hooks.** Whiska routes and stores, and decides
  nothing by reading prose: no scoring, and a turn's kind is its marker's alone
  (ADR-0009). A `## Summary` heading decides only what Whiska keeps and how much
  `whiska show` prints (ADR-0089). What takes judgment is in a brief, which a capable model reads; what must
  hold whatever the model decides is a deny rule a mouse starts with, or the
  `PreToolUse` hook's hold (ADR-0011).
- **An answer goes through `whiska reply`, as the person's words.** It is saved against the
  question and the mouse's own hook takes it (ADR-0080). The main session never types into
  a mouse's pane: text typed there reaches the mouse but leaves the question holding the
  one delivery slot (ADR-0008).

## Why

Whiska asked something of the model at about twenty points: rules printed by a
`SessionStart` hook on every start, resume, `/clear` and compaction; a line after
compaction; nineteen skills under `~/.claude/skills`, listed by description in every
session on the machine, Whiska's or not, mice included; `keep` markers read from two
`CLAUDE.md` files; finish options written out as prose in a skill. Nobody could open one
file and read what a session had been told. A worker in First Mate is told once, by a
brief file written before its pane exists, and Orca asks the model nothing; both work.

A step in prose is followed most of the time, and a command every time. Spawning a mouse
was eight steps of prose in `spawn-worktree`; landing a branch and opening its merge
request, about 170 lines of a skill's side file. No test reached a step of prose.

`--append-system-prompt-file` puts the brief in the system prompt, which Claude Code
sends on every request and keeps across `/clear`, a resume and compaction, so a session
never needs telling again. A mouse's task is not Whiska's words but the person's, so it
is not in the brief: it is the mouse's first prompt, typed once Claude is up. A brief that
held the task, with "Start on the task in your Whiska brief." typed after it, read as a
pointer to a file: mice ran `cat .whiska-brief.md` for what their system prompt already
held.

## Considered options

- **Keep the `SessionStart` hook as a fallback** for a session started by hand. Two
  sources again, and the hand-started session is the one case the person can see: instead
  `whiska start` inside a session started without the brief says to restart it through
  `whiska start`, and `whiska doctor` warns of a main session running without it.
- **The task inside the brief**, which keeps it across `/clear` and compaction word for
  word. It was built first, and needs a line typed to start on it; the line sent mice
  back to the file. A mouse is rarely cleared, and a build mouse's spec carries the task
  by its first compaction.
- **The whole brief as the first prompt.** A rule in a user turn is summarised at
  compaction and gone at `/clear`, and the end-of-turn markers must hold on every turn.
- **The task as Claude's positional prompt on the launch line**, as First Mate does.
  herdr types that line at a shell prompt, so a task of several lines would rest on its
  quoting; herdr's `agent.prompt` sends a bracketed paste while Claude Code takes one.
- **Keep a few skills** — the cold review, merge-request comments — as forked jobs. Each
  is a few lines of the build brief, and a skill is one more file in every session's list.
- **Inline `--append-system-prompt <text>`.** A brief of forty lines on a command line
  typed into a shell, quoted every time.
- **Keep the old briefs under a retired folder** for reference. Git history has them.

## Consequences

- A session started by hand, outside `whiska start` or `whiska spawn`, has no brief. Its
  hooks still hold the hard rules; nothing else reaches it.
- `whiska init` deletes the skills an older Whiska wrote, folder and all once empty, where
  each is a plain file of its own; one reached through a symlink is the person's
  (ADR-0056), kept and named so they can delete it where it lives. It takes out an older
  `SessionStart` entry of Whiska's and leaves anyone else's. `whiska doctor` names either
  leftover, in the repo and in `~/.claude`, with init as the fix (ADR-0038). A block an
  older install wrote into a `CLAUDE.md`, before ADR-0081's install took those out, is
  left for the person.
- The hook socket's protocol loses `--global` and the `session-start` hook, and the shim
  its branches for them (ADR-0033, ADR-0035).
- Whiska types into a mouse's pane when the person spawns it, its task, and when they
  send it something, one fixed line (ADR-0044). The task follows a line `Your task:`
  and a blank one, so it never opens the prompt: Claude Code runs a prompt opening with
  `!` as a shell command, outside every hook, and one opening with `/` as a slash
  command. Its carriage returns become newlines. A task file that is not UTF-8 text, or
  holds a control character but tab or a line break, is refused before anything is
  created: such a character could end herdr's paste early and reach Claude Code as
  keystrokes.
- A mouse cleared with `/clear` no longer knows its task; after a compaction it has the
  summary's version of it.
- Changing what a session is told is editing one file. Tests pin that each brief renders
  whole and the marker's bytes present.

Supersedes ADR-0081 and ADR-0022.

Changed on 2026-10-14: a mouse's task is its first prompt, typed by `whiska spawn`, where
it was written into the brief and a fixed line typed to start on it.
