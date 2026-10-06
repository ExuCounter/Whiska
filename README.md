# Whiska

Run several Claude Code sessions at once, each in its own git worktree. Whiska keeps them
out of each other's files, and when one needs a decision it types a single line into *your*
session — with an id you answer by.

## Install

Requires macOS or Linux, git, Elixir ~> 1.19 on OTP 28 to build, and
[herdr](https://herdr.dev), the terminal multiplexer Whiska reads pane status from and
types into. On Linux, systemd keeps the owl running and `notify-send` (libnotify) shows its
notifications; without systemd — most containers — the owl runs in a pane instead.

```bash
brew install herdr              # or, on Linux: curl -fsSL https://herdr.dev/install.sh | sh

git clone git@github.com:ExuCounter/Whiska.git && cd Whiska
mix deps.get && mix escript.build
cp whiska ~/.local/bin/        # anywhere on your PATH
```

## Set it up

Two commands per repo, one per machine. Order matters: the owl has to be told about the
repo before it is put under launchd or systemd, which start it with no arguments.

```bash
cd your-repo
whiska init                    # hooks, statusline, skills and CLAUDE.md block
git add .claude CLAUDE.md && git commit -m "chore: enable whiska"

whiska owl .                   # record this repo — runs in the foreground, Ctrl-C it
whiska owl install             # the owl under launchd or systemd: at login, and after a crash
```

On Linux, systemd stops the owl when your last session ends. To keep it running after you
log out, run `loginctl enable-linger` once; `whiska doctor` reminds you while it is off.

Then, in the herdr pane you want your main session in — the one pane questions are
delivered to:

```bash
whiska start                   # records this pane, and starts Claude Code in it
```

From inside a session that is already running, `! whiska start` records the pane and
starts nothing; the `!` prefix runs it inside the session, so no restart is needed.
Every other session in this checkout is told on its own statusline that answers do not
land there.

```bash
whiska doctor                  # is it working? every failing line names its own fix
```

## Use it

Ask your main session to start a task in a worktree. When that session finishes a turn,
one line arrives in yours:

```
🐱 feat-delivery needs a decision · #12 · "3 questions ready, see above" · 2 more open
```

```bash
whiska questions               # everything waiting on you here, one line each
whiska questions 12            # that one in full
whiska reply 12 "go with A"    # saved, and that session's doorbell rung; #12 is answered
```

One at a time, and only while your pane is idle and you are not mid-draft; the rest queue
silently. Your statusline shows them, drawn under your own:

```
~/projects/whiska  main ✔
🐭 feat-watch-board     working  12m     A board the owl writes
🐭 feat-quiet-marker    idle     1h 33m  waiting on you for 4m 12s · #52 · "sqlite or a plain file?"
🐭 fix-doctor-probe     working  4m      Bash mix test
🐭 feat-owl-snapshot    blocked  2h 5m   permission prompt in pane
🐭 style-header-polish  idle     3d 4h   Header spacing on narrow panes
```

The words are the project's own: a **mouse** is one of those task sessions, a **house** is
one repo's storage, the **owl** is the one background process watching every house, and a
question waits on the **doorstep** until the owl collects it —
[`CONTEXT.md`](CONTEXT.md) defines each.

## What you get

- **Nothing is lost while the owl is down** — a mouse writes its message into the repo and
  carries on; the owl collects it whenever it is back.
  [Details](docs/internals.md#the-owl-the-house-the-doorstep)
- **One question at a time** — the next goes only when your pane is idle, you are not
  half-way through typing, and the one before it is settled. A "finished" line waits on
  nothing and goes ahead of the queue.
- **A mouse that moved on cannot wedge the queue** — its newer question replaces its own
  older ones.
- **Answers are routed for you** — `whiska reply 12` saves the answer and rings mouse #12's
  own pane, whichever branch and worktree that is. The mouse's own hook hands the answer
  over whole, multi-line and all, and the owl rings again until it is taken.
- **A board where you are already looking** — a row per live mouse in this repo's
  statusline, five at most, drawn under your own line with nothing of yours replaced.
  [Details](docs/internals.md#this-repos-board-in-claude-code)
- **Mice stay out of each other's files** — a build mouse is denied writes into the main
  checkout and the worktrees beside it; a sniff mouse is denied them everywhere. Not a
  sandbox — see below.
  [Details](docs/internals.md#what-is-enforced)
- **The owl comes back by itself** — launchd on macOS, or systemd on Linux, restarts it after
  a crash and at login, and it reopens exactly the houses it had. [Details](docs/internals.md#keeping-the-owl-awake)
- **Nothing is ever deleted** — questions, mouse records and collected entries are kept, and
  no worktree is ever touched.
- **Broken Whiska never blocks your session** — the hook complains on stderr and allows the
  call rather than denying everything.
- **It fits the config you already have** — `init` merges into the repo's own
  `.claude/settings.json`, leaves other people's hooks alone, refuses rather than overwrite
  what it cannot parse, and `whiska uninstall` takes it back out. Per repo, and only after
  you run it. [Details](docs/internals.md#what-whiska-init-writes)
- **`whiska doctor` runs the real thing** — prerequisites, the hooks through the committed
  shim, the house, the doorstep, the backstop, the queue, every mouse record; each failing
  line names its own fix. [Details](docs/internals.md#a-full-whiska-doctor-run)

## Commands

```
whiska questions [<id>|--full]  what is waiting on you in this repo
whiska reply <id> <text>        answer — saved, then handed to that mouse by its own hook
whiska close <id>               settle one by hand, with no answer
whiska waiting [--json]         the same, across every repo on the machine
whiska jump [<repo|branch>]     focus the session of whatever needs you most

inbox                           one word each, installed by `whiska init --global`
show [<id>]                     under ~/.whiska/bin and as slash commands in the main
reply <id> <text>               session: inbox = waiting, show = questions, dismiss =
dismiss <id>                    close; the long names keep working
away                            nothing is delivered anywhere until `resume`
focus <branch>                  only that mouse's questions reach this repo's session
hold <branch>                   that mouse stops where it is; `resume <branch>` lifts it
resume [<branch>]               end away and focus, or lift one hold; oldest first
whiska watch                    this repo's board, printed once
whiska mice                     what is alive here — branch, mode, pane, uptime, pickups
whiska worktrees                linked worktrees, their herdr workspace and pane, tab-separated
whiska doctor                   check this repo end to end; exits 1 on any failure
whiska statusline [--here]      the tab-bar line, or this repo's board
whiska mode [build|sniff]       this mouse's mode; sniff writes nothing, anywhere
whiska init [--global]          install into this repo's .claude/, or into ~/.claude
whiska uninstall [--global]     take it back out; the house is untouched
whiska start [--force]          record this herdr pane as the repo's main session, and
      [--no-claude]             start Claude Code in it if nothing is running there
whiska owl [install|start|stop|uninstall]
```

`whiska --help` has the full text for each.

## Advanced

- **A repo that cannot carry a committed `.claude/`** — `whiska init --global`, once, for
  every repo on the machine. A repo that ran `whiska init` still wins there.
  [Details](docs/internals.md#the-global-install).
- **The machine-wide tab-bar line** — `whiska owl install` writes
  `~/.whiska/herdr-status.sh` and prints a `tab_bar_right` entry; paste it into
  `~/.config/herdr/config.toml` yourself and run `herdr server reload-config`.
  [Details](docs/internals.md#wiring-the-two-statuslines).
- **`keep` on a `CLAUDE.md` block marker** — claims that part so `init` never rewrites it.
  [Details](docs/internals.md#the-claudemd-block).
- **`WHISKA_BIN` and `WHISKA_ESCRIPT`** — override how the hook shim finds the binary and
  the Erlang runtime.
- **What the rules actually cover** — a build mouse cannot write into the main checkout or
  the worktrees under it; a sniff mouse cannot write at all. **Neither is a sandbox**: a
  path elsewhere on the machine is allowed, reads are never policed, and only
  `Write`/`Edit`/`MultiEdit`/`NotebookEdit`/`Bash` go through the hook.
  [Details](docs/internals.md#what-is-enforced).

## Docs

| | |
|---|---|
| [`CONTEXT.md`](CONTEXT.md) | The glossary — the canonical name for every concept |
| [`docs/adr/`](docs/adr/README.md) | Every architectural decision, one file each. Binding |
| [`docs/architecture/`](docs/architecture/README.md) | C4 diagrams, including two end-to-end flows |
| [`docs/internals.md`](docs/internals.md) | What `init` writes, what is enforced, how a question travels, cold start |
| [`specs/spec.md`](specs/spec.md) | The long-form design narrative |

Where the spec and an ADR disagree, the ADR wins.

## Development

Elixir/OTP, SQLite via Ecto, one escript serving both the per-event hooks and the owl.

```bash
mix deps.get
mix test                       # everything but the end-to-end test
mix test.e2e                   # the real binary through a private herdr, ~50 s
mix format --check-formatted
mix escript.build
```

If you contribute: ADRs are binding — if the right change conflicts with one, say so and
change the ADR in the same piece of work. And use the repo's words; `CONTEXT.md` lists the
synonyms that were rejected and why.

## License

Not yet chosen.
