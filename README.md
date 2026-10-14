# Whiska

Run several Claude Code sessions at once, each in its own git worktree. Whiska keeps them
out of each other's files, and when one needs a decision it types a single line into *your*
session, with an id you answer by.

```
🐱 feat-delivery needs a decision · #12 · "3 questions ready, see above" · 2 more open
```

```bash
whiska questions               # what is waiting on you in this repo, one line each
whiska reply 12 "go with A"    # answers #12 and rings that session
```

## Install

Needs macOS or Linux, git, Elixir ~> 1.19 on OTP 28, [herdr](https://herdr.dev) (the
terminal multiplexer Whiska works through) and `nc` with `-U` (macOS has it; on Linux
install `netcat-openbsd`).

```bash
brew install herdr              # Linux: curl -fsSL https://herdr.dev/install.sh | sh
git clone git@github.com:ExuCounter/Whiska.git && cd Whiska
mix deps.get && mix escript.build
cp whiska ~/.local/bin/         # anywhere on your PATH
```

## Set up

In your repo, in this order:

```bash
cd your-repo
whiska init                     # three hooks and their shim; no skills
git add .claude && git commit -m "chore: enable whiska"
whiska owl .                    # record the repo; Ctrl-C it
whiska owl install              # keep the owl running (launchd / systemd)
```

Then, in the herdr pane you want questions delivered to:

```bash
whiska start                    # records this pane, starts Claude Code in it
whiska doctor                   # every failing line names its fix
```

Linux with systemd: run `loginctl enable-linger` once so the owl survives logout. Adding
another repo later takes [one more step](docs/internals.md#keeping-the-owl-running).

## Use

Ask your main session to start a task in a worktree. When that task needs you, one line
arrives in your session. Answer with `whiska reply <id> "<text>"`. Lines come one at a
time, and only while you are idle and not typing; the rest queue. When a task is
finished, say "land", "pr" or "drop" and your main session runs it.

Each session is told what it is by one file, its brief, which Claude Code is started with:
[`priv/briefs/`](priv/briefs) holds the main session's, a build mouse's and a sniff
mouse's. Change what a session is told by editing one of them.

Words: a **mouse** is a task session, the **owl** is the background process watching every
repo. [`CONTEXT.md`](CONTEXT.md) has the rest.

Mice run without permission prompts. Each starts with a deny list: a mouse cannot run your
commands, and one that only investigates has no tools to edit files. It is not a
sandbox ([details](docs/internals.md#what-is-enforced)). No question or record is ever
deleted, Whiska takes a worktree down only once its branch has landed, and a broken
Whiska never blocks your session.

## Docs

| | |
|---|---|
| [`docs/reference.md`](docs/reference.md) | Every command, `whiska where`, `owl.sock`, environment variables |
| [`docs/internals.md`](docs/internals.md) | What `init` writes, what is enforced, how a question travels, the owl, the doctor |
| [`CONTEXT.md`](CONTEXT.md) | The glossary — the canonical name for every concept |
| [`docs/adr/`](docs/adr/README.md) | Every architectural decision, one file each. Binding |
| [`docs/architecture/`](docs/architecture/README.md) | C4 diagrams, including two end-to-end flows |

## Development

```bash
mix test                       # all but end-to-end
mix test.e2e                   # real binary through a private herdr, ~50 s
mix format --check-formatted
```

ADRs are binding: if the right change conflicts with one, say so and change the ADR in the
same piece of work. Use the words in `CONTEXT.md`.

Licence: not yet chosen.
