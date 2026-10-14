# Internals

What happens under the hood, for when something is wrong. The *why* of each choice is in
[`docs/adr/`](adr/README.md); this file only says what happens.

- [What `whiska init` writes](#what-whiska-init-writes)
- [What is enforced](#what-is-enforced)
- [How a question reaches you](#how-a-question-reaches-you)
- [The global install](#the-global-install)
- [Keeping the owl running](#keeping-the-owl-running)
- [Wiring the tab bar and the sidebar](#wiring-the-tab-bar-and-the-sidebar)
- [`whiska doctor`](#whiska-doctor)
- [A change is not live until the thing running it restarts](#a-change-is-not-live-until-the-thing-running-it-restarts)
- [What is not built yet](#what-is-not-built-yet)
- [Speed and size](#speed-and-size)

## What `whiska init` writes

`whiska init` writes into the repo's own `.claude/`, which you commit so the rules travel
with the repo (ADR-0056):

```
git add .claude && git commit -m "chore: enable whiska"
```

| File | What it is |
| --- | --- |
| `.claude/settings.json` | Three hooks, below. Your other settings and hooks are left alone; a file that will not parse is refused, never overwritten. |
| `.claude/hooks/whiska.sh` | The shim every hook calls. It finds the `whiska` binary and Erlang when the hook fires, so nothing committed names your machine (ADR-0035). `WHISKA_BIN` and `WHISKA_ESCRIPT` override the lookup. |

| Hook | What it does |
| --- | --- |
| `PreToolUse` | Stops a held mouse ([below](#what-is-enforced)). Fires only for `Write`, `Edit`, `MultiEdit`, `NotebookEdit` and `Bash`. |
| `Stop` | Leaves a mouse's finished turn on the doorstep. |
| `UserPromptSubmit` | Hands a mouse the answer you gave it (ADR-0080). |

Re-running `init` is safe, and it leaves a file alone when nothing in it would change. It
also takes out what an older Whiska wrote: its skills under `.claude/skills/`, folder and
all once empty, and its `SessionStart` hook entry. A skill reached through a symlink is
yours, so it stays, and `init` names it for you to delete where it lives (ADR-0056).

### What a session is told: its brief

Everything Whiska tells a session is one file, its brief, which Claude Code is started with
(`claude --append-system-prompt-file <brief>`, ADR-0088). Nothing is
written into `CLAUDE.md`, and no skill is installed.

| Session | Brief | Where it is written |
| --- | --- | --- |
| Main session | `priv/briefs/main.md` | `.git/whiska/main.md`, by `whiska start`, which starts Claude with it |
| Build mouse | `priv/briefs/build.md` | `.whiska-brief.md` at the worktree root, by `whiska spawn` or `whiska shape`; git ignores it |
| Sniff mouse | `priv/briefs/sniff.md` | the same |

A mouse's task is not in its brief: `whiska spawn` types it as the mouse's first prompt,
so a mouse cleared with `/clear` no longer has it.

The brief sits in the session's system prompt, so `/clear` and `/compact` keep it. A Claude
you start by hand gets none: `whiska start` in such a session says to restart it, and
`whiska doctor`'s `main brief` line warns about it.

One line Whiska reads in your `CLAUDE.md`: `checks:` under a `## Finish` heading, the
command `whiska land` runs after copying a branch's commits. The rest of the file loads as
Claude Code loads it.

## What is enforced

A shaped mouse starts in Claude Code's bypass mode, with a deny list in
`.whiska-settings.json` at its worktree root (ADR-0090). Claude
Code enforces it; nothing else asks before a tool call.

- **A mouse may not run your commands**: `away`, `focus`, `hold`, `resume`, `reply`,
  `dismiss` and `close`, as a word or as `whiska <word>`, nor the main session's `whiska
  spawn`, `send`, `land`, `pr` and `drop` (ADR-0079).
- **A sniff mouse has no `Edit`, `Write` or `NotebookEdit`.** Its research document is
  its final message, which Whiska keeps (ADR-0069, ADR-0089).
- **A held mouse may do nothing** the `PreToolUse` hook sees, until `resume <branch>`
  (ADR-0079). It stops at its next write or shell command and says where it stopped.
  This is the hook's one rule, since you set it while the mouse runs.

What this is not:

- **Not a sandbox, and not a security boundary.** A mouse can write anywhere you can,
  the main checkout included; its brief tells it to stay in its worktree. The deny rules
  match the command as written, so `env`, a full path, `bash -c` or a nested `claude -p`
  gets round them.
- **A mouse started by hand without `whiska shape` has no deny list.** Run `whiska shape`
  in its worktree and restart Claude with the flags it prints.
- **A broken Whiska never blocks you.** If the binary is missing, the shim says so on
  stderr and allows the call. If the house will not open, the mouse is taken as not held,
  with a warning.

## How a question reaches you

1. **A mouse gets its identity** when `whiska shape` sets it up before Claude starts, or
   else the first time one of its hooks fires (ADR-0069, ADR-0002): an opaque `mouse_id`
   in `.whiska-mouse` at the worktree root, and a record in the repo's house,
   `<main-checkout>/.git/whiska/whiska.db`.
2. **A finished turn goes on the doorstep.** The `Stop` hook leaves the mouse's whole final
   message in `.git/whiska/doorstep/`, one JSON file per entry. The owl writes it when it
   answers on `~/.whiska/hook.sock`; the escript writes it when the owl does not
   (ADR-0036). Either way it lands.
3. **The owl collects it**: at once when it wrote the entry, when herdr says the mouse's
   pane is idle, when a house opens, and on a 60-second backstop. Collected entries are
   removed once recorded; the row is the history (ADR-0007).
4. **The entry becomes a question**, sorted by the invisible marker the mouse ended on
   (ADR-0009): needs a decision, finished, or no marker. No marker is delivered too, so a
   forgotten marker makes noise rather than silence. An entry whose worktree is gone is
   recorded as orphaned.
5. **One question at a time goes to your main session** (ADR-0008): when herdr says that
   pane is Claude and idle, nothing else is out waiting, and you are not typing
   (ADR-0047). The first of a new round waits 8 seconds so the count is right. The rest
   queue. `away`, `focus` and `hold` decide what may reach you (ADR-0079). What is typed is
   one line, not the message:

   ```
   🐱 feat-delivery needs a decision · #12 · "3 questions ready, see above" · 2 more open
   ```

   The main session's brief tells it to run `whiska show` on that line, write the question's
   heading and links from the facts it prints, show its message, and stop. You say what happens next: an answer, "land", "pr", "drop", or a
   note for the mouse, and it runs the command for it.
6. **You answer by id**: `whiska reply 12 "go with A"` (ADR-0005). The answer is saved,
   the question is answered and the delivery slot is free. Then a short 🔔 doorbell line is
   typed into the mouse's pane, and the mouse's own `UserPromptSubmit` hook hands it the
   answer (ADR-0080). The owl rings again, up to three times, while the answer is not
   taken. `whiska reply` needs no owl. `whiska close 12` settles a question with no answer.

A newer question from the same mouse supersedes its earlier ones, so a mouse that moved on
cannot block the queue. The main session is the herdr pane `whiska start` recorded
(ADR-0066); it refuses to replace one still running Claude unless `--force`.

[`docs/architecture/`](architecture/README.md) draws this flow, and the `PreToolUse` one.

## The global install

A repo you cannot commit a `.claude/` to (someone else's, or one whose owners will not take
another tool's hooks) can use the same install from `~/.claude` instead, once for every
repo on the machine (ADR-0056):

```
whiska init --global
```

It writes the same shim and hooks under `~/.claude`, plus the one-word commands as shell
commands in `~/.whiska/bin`; put that on your `PATH` to type `inbox` or `reply` in a
shell. A word another program already answers to is skipped. Like the repo install, it
deletes the skills an older Whiska wrote under `~/.claude/skills` and its `SessionStart`
entry, and names a skill reached through a symlink rather than deleting it.

A repo that ran `whiska init` keeps its own copy, and the global one stands down there. To
hand a repo over to the global install, run `whiska uninstall` in it and commit what it
removes. `whiska uninstall --global` does the same for `~/.claude`. Neither touches the
house.

If a file under `~/.claude` is a symlink into a dotfiles repo, Whiska writes through the
link and prints where each change landed, so you can commit it there.

## Keeping the owl running

```
whiska owl .          # run the owl in the foreground and record this repo's house
whiska owl install    # hand it to launchd (macOS) or systemd (Linux), and start it
whiska owl stop       # stop it; it stays stopped until `whiska owl start` or next login
whiska owl start
whiska owl uninstall  # remove the job; the log and the record stay
```

The service manager starts the owl at login and restarts it after a crash, never after
`whiska owl stop` (ADR-0040). It runs `~/.whiska/owl.sh`, which finds the binary at each
launch, and logs to `~/.whiska/owl.log`. Install from a herdr pane: `HERDR_SOCKET_PATH`
and your `WHISKA_*` variables are copied into the job.

The owl opens every house in `~/.whiska/houses` (ADR-0039). A house gets there the first
time `whiska owl <repo>` opens it. Only one owl runs at a time, so to add a repo while the
owl is installed:

```
whiska owl stop
whiska owl ~/src/other-repo    # record it; Ctrl-C once it prints "Opened"
whiska owl start
```

On Linux, run `loginctl enable-linger` once, or systemd stops the owl when you log out.
With no systemd at all (most containers), run `whiska owl` in a pane.

## Wiring the tab bar and the sidebar

Both are rows in your own herdr config, `~/.config/herdr/config.toml`. Whiska never writes
that file: paste the rows in and run `herdr server reload-config`. `whiska doctor` prints
any row you are missing.

### The statusline, on herdr's tab bar

One line for the whole machine (ADR-0048):

```
🦉 watching
🦉 watching · 🐱 myrepo · ⌃a space
🦉 watching · away · 🐱 2 whiskas · ⌃a space
🦉 owl down
```

`🦉 owl down` means the owl did not answer within a second, or it has doorstep entries it
should have collected by now. `🦉 nc missing` and `🦉 nc cannot reach the owl` mean the
tool is the problem, not the owl. `🐱` is whatever is waiting on you across the machine.

`whiska owl install` writes the script herdr runs, `~/.whiska/herdr-status.sh`, and prints
the row with your path in it. The script asks the owl over `owl.sock` and starts nothing.
Its one argument is the key you bound to reach what is waiting, shown only when something
is:

```toml
[ui]
tab_bar_right = [
  { type = "command", command = "/Users/you/.whiska/herdr-status.sh '⌃a space'", interval_seconds = 5, timeout_seconds = 2 },
]
tab_bar_right_separator = " · "
```

### Each mouse's line, in herdr's sidebar

The owl writes a line under each mouse's workspace (herdr 0.9 or newer), and one under
the main checkout's for the whole repo (ADR-0082):

```
myrepo
  ⏳ gated: you're typing
feat/quiet-marker
  ❓ 142K · waiting on you · 4m
  sqlite or a plain file?
fix/doctor-probe
  ✖ 88K · stuck 6m
  Bash mix test
feat/cache-ttl
  ◐ 61K · Cache TTL per tenant
```

The first line is the state, after the mouse's context size; the rest carry the question. `❓` waiting on you, `✅`
finished, `✖ stuck`, `⏳` queued behind another question (the one above it), `🎯` and `💤` waiting behind a
focus or away, `⏸` held, `↩` picked up after its turn died, `◐` working (it spins, so a
still one means the owl stopped), `○` idle. `✖ no pane`, `⚠ many panes` and
`? herdr can't say` mean Whiska cannot find the mouse's pane. Lines expire after 30
seconds, so a dead owl's lines go away rather than lie. `whiska watch` prints the same
lines on the spot.

Each line is coloured by its first symbol. The rows, shortened; `whiska doctor` prints them
in full:

```toml
[ui.sidebar.spaces]
rows = [
  ["state_icon", { token = "workspace", fg = "#586e75", dim = false }],
  ["branch", "git_status"],
  [{ token = "$whiska", fg = "#657b83", dim = false, rules = [
    { starts_with = "❓", fg = "#2aa198" },
    { starts_with = "⚠", fg = "#dc322f" },
    # … one rule per symbol
  ] }],
  [{ token = "$whiska_q", fg = "#93a1a1" }],
  [{ token = "$whiska_q2", fg = "#93a1a1" }],
]
```

Whiska draws nothing in Claude Code's own statusline. `whiska init` takes out the one an
older version wrote, and puts back yours if it had replaced it.

## `whiska doctor`

Run it from the main checkout or any worktree when the mice have gone quiet. It checks,
and never repairs (ADR-0038): the binary, Erlang, herdr, the owl, the hooks (by running
them, leaving nothing behind), the house, the doorstep, the main session, the questions
and every mouse. Each failing line names its fix. `FAIL` means a question would be lost;
`warn` means degraded, nothing lost. It exits 1 on any `FAIL`.

```
whiska doctor — myrepo (/Users/me/projects/myrepo)

  ok    binary                   /Users/me/.local/bin/whiska
  ok    herdr                    reachable at /Users/me/.config/herdr/herdr.sock (12 panes)
  warn  owl                      not running — nothing collects the doorstep
                                 fix: whiska owl
  FAIL  Stop                     not wired — mice here cannot leave questions
                                 fix: whiska init
  ok    house                    /Users/me/projects/myrepo/.git/whiska/whiska.db, schema v14
  ok    doorstep                 nothing uncollected
  warn  main session             not recorded — nothing is delivered until it is
                                 fix: whiska start  (from the main checkout's pane)
  ok    mice                     feat-thing: live pane w1:p3

1 failed, 2 warnings.
```

The `backstop` line catches a quiet half-failure. The owl should collect when herdr says a
mouse went idle; the 60-second timer is only the last resort. If the timer collects
anything, questions still arrive, a minute late, and the doctor warns that herdr's signal
is not reaching the owl.

## A change is not live until the thing running it restarts

Three things keep running old code after you replace it, and the doctor checks each by age:

- **The owl keeps the binary it started with.** After
  `cp whiska ~/.local/bin/whiska`, run `whiska owl stop && whiska owl start`. The `owl`
  line says when the binary is newer than the owl.
- **Nothing runs a build you did not install.** The hooks and the owl run the binary on
  your `PATH`; `mix escript.build` alone changes nothing. The `build` line compares
  `./whiska` with the installed copy.
- **A Claude Code session reads its settings once, at start.** After `whiska init`
  changes them, restart Claude in that pane. The `session wiring` line says when a
  settings file changed after the main session started. The shim runs afresh every time,
  so a change to it is live at once. A brief is read at start too: a new build's briefs
  reach a session that `whiska start` or `whiska spawn` starts after it.

## What is not built yet

Pre-1.0 (`v0.0.1`). Every ADR is built except those under "Proposed, not built" in the
[index](adr/README.md), and these parts of built ones:

- `whiska stop` for one house, which needs a per-repo socket (ADR-0003, ADR-0024).
- `whiska reopen` (ADR-0005) and `whiska cleanup` (ADR-0061) as commands.
- Push approval (ADR-0011).
- Relaunching a stuck mouse, then telling you (ADR-0026, ADR-0067).
- Waking a mouse for its merge request's review or failed pipeline, and reading a GitHub
  pull request (ADR-0060).

## Speed and size

Measured on Apple silicon, macOS, OTP 28, Elixir 1.19, 30 runs each:

| What runs | Time |
| --- | --- |
| A hook, through the shim, with the owl answering (ADR-0033) | ~16 ms |
| A hook, through the escript, when the owl does not answer | ~245 ms |
| `whiska --version`, the escript's boot floor | 126 ms |
| The first run ever, which also unpacks SQLite | 627 ms, once |

Most of the escript's time is the Erlang VM starting, which nothing inside the program can
remove. That is why every hook asks the running owl first.

The binary is 3 MB because it carries SQLite's native library inside it: an escript is a
zip, and native code cannot be loaded out of a zip. The library is unpacked to
`~/.cache/whiska/` on first run (ADR-0028).
