# Whiska

An Elixir/OTP coordinator that manages Claude Code worker sessions ("mice") running in
isolated git worktrees.

`CONTEXT.md` is the glossary — **Whiska**, **mouse**, **mouse_id**, **question**,
**house**, **owl**, **build/sniff mode**. `docs/adr/` records why things are the way they
are, and those decisions are binding.

## Status: delivery

v0.0.1 proved the plumbing — identity, storage, one enforced rule (ADR-0030). The owl
slice added a house per repo, its herdr subscription, and doorstep collection (ADR-0036).
This slice closes the loop: a collected question is **delivered** to the main session
(ADR-0008) and answered by id (ADR-0005). The owl remembers which houses it has open
(ADR-0039) and runs under `launchd` (ADR-0040). Not yet: `whiska stop` for one house, the
per-repo socket, cross-repo commands, `whiska reopen`, push approval.

```
mix deps.get
mix test          # 596 tests
mix escript.build # produces ./whiska
```

### Getting a question in front of you

Three steps, in this order, once per repo:

```
whiska init                  # hooks into .claude/settings.json (once, committed)
! whiska start               # from INSIDE your main Claude Code session, in the main checkout
whiska owl install           # once per machine: the owl under launchd, restarted if it crashes
whiska owl .                 # once per repo: open this house; the owl remembers it from then on
```

`whiska owl install` puts the owl under a user LaunchAgent (ADR-0040) and starts it; see
"Keeping the owl awake" below. Before the first install, `whiska owl` in any pane runs it
in the foreground instead.

`whiska start` records the herdr pane it is run from as the repo's **main session**
(ADR-0020) — the one pane the owl delivers to. Typed as `! whiska start` inside the
session, the Bash tool inherits the pane id, so a session that is already running can be
recorded without restarting it. It refuses to replace a main session that is still running
Claude, naming the pane, unless `--force`; it does not launch Claude Code itself yet, which
the spec describes and a later slice will add. Run in a worktree it refuses: mice are not
main sessions.

The owl then **delivers**. A question goes to the main session only when herdr reports
that pane as `claude` + `idle` and no other question is already out waiting for its answer
(ADR-0008); anything else queues silently. The first question of a fresh round waits 8 s so
the count in the line is right. `claude` + `unknown` is delivered anyway, and the line says
so. What is typed is one line — a pointer, not the message:

```
🐱 feat-delivery needs a decision · #12 · "3 questions ready, see above" · 2 more open
```

No command in it: the `whiska-delivered` skill that `whiska init` installs recognises the
line by its shape and runs `whiska questions 12` for you, shows the question, and stops
(ADR-0022). Answering is still yours to do:

```
whiska questions             # what is waiting on you, one line each
whiska questions 12          # that one in full
whiska reply 12 "go with A"  # typed into the mouse's pane; #12 becomes answered
whiska close 12              # settled some other way, no answer
```

`whiska reply` and `whiska close` open the house directly and ask herdr to type; they
need no owl running and no socket. A newer question from the same mouse **supersedes**
its earlier open or delivered ones (ADR-0037), so a mouse that moves on cannot wedge the
queue; `whiska close` covers the rest.

### Keeping the owl awake

```
whiska owl install    # write ~/Library/LaunchAgents/com.whiska.owl.plist and load it
whiska owl stop       # ask the owl to exit; it returns at login, or on `whiska owl start`
whiska owl start      # start it now
whiska owl uninstall  # unload the job and remove it; the log and the record stay
```

The LaunchAgent starts the owl at login and restarts it if it crashes — `KeepAlive` only on
a crash, so `whiska owl stop` is a clean exit that stays stopped (ADR-0040). The job runs
`~/.whiska/owl.sh`, a wrapper generated from the same shell the hook shim uses, so the
binary and the Erlang runtime are found at every launch rather than baked in; stdout and
stderr go to `~/.whiska/owl.log`. `HERDR_SOCKET_PATH` and the `WHISKA_*` overrides are
copied into the job from the shell you install from, so install from a herdr pane; with
nothing to copy the owl falls back to herdr's default socket.

launchd starts the owl with no arguments, so it opens exactly the houses in its record
(`~/.whiska/houses`, ADR-0039). With the record empty it idles and waits; `whiska owl
<repo>` in the foreground is how a house first gets recorded — Ctrl-C it afterwards and
the supervised owl picks it up on `whiska owl start`.

Two owls would collect the same doorsteps, so `install` refuses while any owl is in the
process table and prints the handover (Ctrl-C the foreground one, install again), and the
foreground `whiska owl` refuses while launchd's owl is running — unless it *is* launchd's
owl, which it tells by pid (ADR-0040's 2026-09-28 note). `whiska stop` is not the
owl's stop: it shuts one house (ADR-0003) and is not built until the owl has a socket.

### The owl, the house, the doorstep

```
whiska owl            # run the owl in the foreground, house open for this repo
whiska owl ~/a ~/b    # ...or for each repo named (a worktree path names its repo)
```

When a mouse finishes a turn, its `Stop` hook (`whiska hook stop`, installed by
`whiska init`) writes the whole final message to the repo's **doorstep** —
`<main-checkout>/.git/whiska/doorstep/`, one JSON file per entry, stamped with `mouse_id`,
branch and time. It never opens a socket, so whether the owl is running changes nothing
about what the mouse does (ADR-0036).

The owl **collects** the doorstep when herdr reports that mouse's pane idle, when a house
opens, and on a slow backstop timer. Each entry becomes a question, classified by its
marker alone (ADR-0009): `[worktree-status: needs-decision]` → open; `done` → open too,
delivered as "finished" with no reply offered and closed the moment it is sent; no marker
→ `unmarked`, and open — forgetting the marker makes noise rather than silence. An entry whose worktree is gone is recorded as `orphaned`. Collected entries are
renamed `.collected`, never deleted (ADR-0007), so `ls *.json` on the doorstep is exactly
what is still waiting.

The house finds each mouse's herdr pane by its `cwd`, records it, and subscribes to that
pane's status changes; a pane that closes or exits marks its mouse dead and orphans its
open questions (ADR-0026). Nothing on disk is ever touched.

herdr is the one boundary with a fake behind it in tests (`Whiska.Herdr`, ADR-0031); the
real client is checked against an in-test server speaking herdr's wire protocol.

### What is waiting on you

```
whiska questions       # open and delivered questions, then orphaned, then uncollected
whiska questions <id>  # one question in full
whiska statusline      # the line herdr's tab bar shows, for the whole machine
```

`whiska questions` lists every question still waiting on you — open, or delivered and
not yet answered — one per line, in delivery's own words:

```
#12  feat-delivery  needs a decision · "3 questions ready, see above"  (sent 14:32)
```

Beneath the list, orphaned questions — whose mouse or worktree is gone — are shown apart
and never counted (ADR-0036), and entries still on the doorstep are counted too, since an
uncollected doorstep usually means the owl is not running.

`whiska init` also writes the worktree protocol into the repo's own `CLAUDE.md`
(ADR-0045) and installs the three skills that drive it — `spawn-worktree`,
`send-to-worktree` and `drop-worktree` (ADR-0046). The block is a nest of named markers,
one pair per part:

```markdown
<!-- whiska:start -->
<!-- whiska:worktrees:start -->   …the decision tree: route into a running mouse, or spawn
<!-- whiska:marker:start -->      …the worktree-status marker a mouse ends every turn with
<!-- whiska:delivery:start -->    …how its question reaches you, and why you never read its pane
<!-- whiska:end -->
```

Re-running `init` replaces each part where it stands, adds one whose markers are missing,
and returns everything outside the outer pair byte for byte — your own text included, and
your own prose sitting between two parts. To make a part yours for good, put `keep` on
its start marker (`<!-- whiska:marker:start keep -->`); Whiska then never rewrites it.
Empty it as well, and the part is dropped for good.

`whiska init` also installs the `/whiska-questions` slash command (ADR-0022).

### The statusline, on herdr's tab bar

One line for the whole machine, drawn once on herdr's tab bar rather than in every Claude
Code session (ADR-0048). The owl's state is always there, so a blank line never passes for
a working Whiska; the rest follows the one-or-many rule and is absent when it has nothing
to say:

```
🦉 watching
🦉 watching · 🐱 feat-auth
🦉 watching · 🐱 3 waiting
🦉 owl down · 🐱 2 waiting
```

`whiska owl install` writes the script herdr runs, `~/.whiska/herdr-status.sh`, and
prints the entry that runs it. That entry is yours — herdr's config is machine-global and
hand-edited, so Whiska never writes it. Paste it into `~/.config/herdr/config.toml`,
commit it with your dotfiles, and `herdr server reload-config`:

```toml
[ui]
tab_bar_right = [
  { type = "command", command = "~/.whiska/herdr-status.sh", interval_seconds = 5, timeout_seconds = 2 },
]
tab_bar_right_separator = " · "
```

`whiska doctor` says whether it took.

`🦉 watching` means the owl is running and collecting; `🦉 owl down` means it is not — no
owl process, or doorstep entries sat uncollected past its backstop. `🐱` is what is
waiting anywhere on this machine, the same reading `whiska waiting` prints: one thing is
named by its mouse's branch, several become a count, nothing waiting says nothing. Until
the owl's global socket exists the owl is found in the process table, the same way
`whiska doctor` finds it.

### What it does

`whiska hook pre-tool-use` reads a Claude Code `PreToolUse` event as JSON on stdin and
either stays silent (allow) or prints a deny decision as JSON on stdout. It always exits
0 — the decision travels in the JSON body, and a non-zero exit would read to Claude Code
as the hook itself having failed.

On the first invocation inside a worktree it mints an opaque `mouse_id`, writes it to
`.whiska-mouse` at the worktree root (ADR-0002), and records the mouse in this repo's
house at `<main-checkout>/.git/whiska/whiska.db`.

### The enforced rules

**A build mouse may not change anything outside its own worktree** (ADR-0013). That
covers `Write`, `Edit`, `MultiEdit` and `NotebookEdit` by their literal target path, and
`Bash` when a command is *both* mutating *and* names a path resolving into the main
checkout — so `sed -i`, a redirect, and `git -C <main> commit` are denied while
`cat <main>/CONTEXT.md` and `grep -r <main>` are not.

**A sniff mouse may not change anything at all** (ADR-0018), including inside its own
worktree — every edit tool is denied outright, and so is any mutating shell command.
Reading is untouched: `Read`, `Grep`, `Glob`, and read-only commands like `git log`,
`git diff` and `grep` all work.

Reads are never policed in any mode. The rules contain *changes*; they are not a sandbox.

Whether a shell command counts as mutating is decided by a read-only allowlist, with
anything unreadable — `eval`, a substitution, a nested `bash -c`, an unknown binary —
treated as mutating. ADR-0034 explains why that direction, and what it costs.

### Modes

```
whiska mode           # what is this mouse?
whiska mode sniff     # investigation only, writes nothing
whiska mode build     # back to making changes
```

Run inside a worktree. The mode is stored in the house keyed by `mouse_id`, so renaming
the branch or moving the folder does not disturb it. If the mode cannot be read, Whiska
assumes `build` and says so on stderr — worktree containment is pure path arithmetic and
keeps working regardless.

### Is it working? `whiska doctor`

```
whiska doctor         # from the main checkout or any worktree of it
```

Delivery only happens when the owl is up and a main session is recorded and idle, and
the statusline only tells you whether the owl is watching. From
the main terminal a broken pipe and a quiet fleet look much the same. The
doctor is what you run when the mice have gone quiet, to learn which silence you are in
(ADR-0038). It checks this repo's prerequisites (binary, runtime, herdr, owl), its hooks
and shim — **by running them**, through the committed shim with a payload outside any
worktree, so nothing is minted or left behind — then its house, its doorstep, its
backstop, its main session and question queue, and whether each mouse record still
matches a real worktree and a live herdr pane.

The backstop line is the one that catches a silent half-failure. Collection is meant to
be event-driven: herdr tells the owl a mouse has gone idle and the owl reads that
house's doorstep then, with a 60 s timer as a last resort (ADR-0036). When the event
stops arriving, nothing breaks — every question still lands, a minute late — so the
doctor watches the last resort instead: it warns when the backstop has collected
anything at all since the owl opened this house, which means the trigger is not reaching
the owl.

It never repairs. Every failing line carries the command that fixes it. `FAIL` means a
question from a mouse here would be lost or never written; `warn` means degraded but
nothing lost. Exit status is 1 on any failure, 0 otherwise.

```
whiska doctor — myrepo (/Users/me/projects/myrepo)

  warn  binary      /Users/me/.local/bin/whiska — not on PATH; the shim falls back here
                    fix: export PATH="$HOME/.local/bin:$PATH"
  ok    runtime     /Users/me/.asdf/installs/erlang/28.1.1/bin/escript
  ok    herdr       reachable at /Users/me/.config/herdr/herdr.sock (12 panes)
  warn  owl         not running — nothing collects the doorstep
                    fix: whiska owl
  warn  launch agent  not installed — the owl is not supervised
                    fix: whiska owl install
                    fix: whiska owl
  FAIL  Stop        not wired — mice here cannot leave questions
                    fix: whiska init
  ok    house       /Users/me/projects/myrepo/.git/whiska/whiska.db, schema v3
  ok    doorstep    nothing waiting
  warn  backstop    collected 4 entries the idle trigger missed, last 12 min ago — the herdr idle trigger is not reaching the owl; check the subscription and the herdr version
                    fix: whiska owl stop && whiska owl start
  warn  main session  not recorded — nothing is delivered until it is
                    fix: whiska start  (from the main checkout's pane)
  ok    questions   none waiting
  ok    mice        feat-thing: live pane w1:p3

1 failed, 3 warnings.
```

### Installing the hooks

```
cd your-repo
/path/to/whiska init
git add .claude/settings.json .claude/hooks/whiska.sh .claude/skills CLAUDE.md
git commit -m "chore: enable whiska"
```

`whiska init` writes the hook into the repo's own `.claude/settings.json` (ADR-0016), so
the rules travel with the repo: anyone who clones it and has Whiska installed gets the
same enforcement. It is safe to re-run, leaves unrelated settings and other people's
hooks alone, and refuses rather than overwriting a settings file it cannot parse.

What it writes, and why each part is the way it is:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Write|Edit|MultiEdit|NotebookEdit|Bash",
        "hooks": [{
          "type": "command",
          "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/whiska.sh\" pre-tool-use"
        }]
      }
    ],
    "Stop": [
      {
        "hooks": [{
          "type": "command",
          "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/whiska.sh\" stop"
        }]
      }
    ]
  }
}
```

- **The matcher lists exactly the tools a rule can deny** — no `*`. `Bash` belongs there
  now that sniff mode denies mutating commands and containment denies ones reaching into
  the main checkout; without it, both rules would silently never fire. `Read`, `Grep` and
  `Glob` are left out on purpose: they are a large share of all tool calls, can never be
  denied, and ADR-0033 is blunt that not running at all beats running fast.
- **Nothing in the committed file is specific to your machine** (ADR-0035). It names only
  `.claude/hooks/whiska.sh`, a shim `init` writes beside it. An earlier version baked two
  absolute paths — the Erlang runtime and the binary — straight into the command, which
  pinned the file to one home directory and one Erlang version, and put a username into a
  shared repo. Check both files in.
- **The shim resolves the runtime when the hook fires**, not when `init` runs. A
  `mix escript.build` binary starts with `#!/usr/bin/env escript`, so it only runs when
  `escript` is on `PATH` — and a hook does not necessarily inherit your shell's. With a
  version manager it is not found at all (`env: escript: No such file or directory`). The
  shim looks on `PATH`, then asks `asdf`; `WHISKA_BIN` and `WHISKA_ESCRIPT` override both.
  No need to re-run `init` after an Erlang upgrade.
- **The shim fails open.** If Whiska is not installed it complains on stderr and allows the
  call, rather than denying every tool call in the session — the same trade
  `Whiska.Hook.PreToolUse` makes on a malformed payload.
- **The extra process is free at this size.** Wrapping the call in a shell costs about
  5 ms, which was the original reason not to. Measured against the real hook it is noise:
  214.5 ms unwrapped versus 204.7 ms wrapped, over 20 runs each — both dominated by BEAM
  boot. ADR-0033's native hook is the thing that will care, and by then the shim is what
  lets `settings.json` stay untouched while the binary behind it changes.

### Cold start

Measured on the development machine (Apple silicon, macOS 25.4, OTP 28, Elixir 1.19),
30 runs each:

| What runs | Per invocation |
|---|---|
| Bare `elixir -e ':ok'` | 177 ms |
| `whiska --version` — escript boot floor | 126 ms |
| **`whiska hook pre-tool-use` — the real job, SQLite included** | **~220 ms** |
| First run ever, which also unpacks the bundled SQLite library | 627 ms, once |

Roughly 126 ms of that is the BEAM booting before any code runs, and the rest is
loading Ecto, db_connection and exqlite. The SQLite work itself — open, migrate, upsert —
is under 2 ms. Nothing inside the program can remove the first 126 ms, which is why
ADR-0033 moves the hook client to a native binary when the owl arrives, and why the
narrow matcher above matters more than it looks: `Read`, `Grep` and `Glob` never pay it.

### Why the binary is 3 MB

An escript is a zip archive. It carries no `priv/` directories, and native code cannot be
`dlopen`ed out of a zip in any case — so SQLite's 1.6 MB native library travels as bytes
embedded in `Whiska.BundledNIF` and is unpacked to `~/.cache/whiska/exqlite-<vsn>/` on
first run. That is the only reason ADR-0030's "single binary" and ADR-0028's "real
SQLite" can both hold. It is scaffolding with a known end: when ADR-0033's native hook
client arrives, the hook stops touching storage entirely and this module is deleted whole.
