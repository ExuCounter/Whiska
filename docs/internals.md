# Internals

The parts of Whiska you only need when something is wrong, or when you want to know why a
choice was made. [`docs/adr/`](adr/README.md) is the authority for every *why* here; this
file is the operational detail around them.

- [What is enforced](#what-is-enforced)
- [How a question reaches you](#how-a-question-reaches-you)
- [What is built, and what is not](#what-is-built-and-what-is-not)
- [What `whiska init` writes](#what-whiska-init-writes)
- [The `CLAUDE.md` block](#the-claudemd-block)
- [The global install](#the-global-install)
- [Keeping the owl awake](#keeping-the-owl-awake)
- [The owl, the house, the doorstep](#the-owl-the-house-the-doorstep)
- [Delivery, in detail](#delivery-in-detail)
- [Wiring the two statuslines](#wiring-the-two-statuslines)
- [A full `whiska doctor` run](#a-full-whiska-doctor-run)
- [Cold start](#cold-start)
- [Why the binary is 3 MB](#why-the-binary-is-3-mb)

## What is enforced

Two rules, both through Claude Code's `PreToolUse` hook, both denied immediately:

- **A build mouse may not change the main checkout** — including the sibling worktrees
  that live under it. `Write`, `Edit`, `MultiEdit` and `NotebookEdit` by their literal
  target path, and `Bash` when a command is *both* mutating *and* names a path resolving
  into the main checkout. So `sed -i`, a redirect and `git -C <main> commit` are denied;
  `cat <main>/CONTEXT.md` and `grep -r <main>` are not.
- **A sniff mouse may not change anything at all**, its own worktree included.

Notes:

- **This is not a sandbox, and it is not a security boundary.** Reads are never policed,
  in any mode. Neither is anything else on the machine: a path outside both the worktree
  and the main checkout — `~/.ssh`, `~/.zshrc`, another repo — is allowed. The rules keep
  parallel sessions out of each other's work; they do not contain code you do not trust.
- **If the house will not open, a sniff mouse degrades to a build mouse.** The mode is
  read from SQLite; on a storage failure Whiska assumes `build`, warns on stderr, and
  carries on — containment is pure path arithmetic and keeps working either way.
- Whether a shell command counts as mutating is decided by a **read-only allowlist** —
  anything unreadable (`eval`, a substitution, a nested `bash -c`, an unknown binary) is
  treated as mutating.
- **Only the tools in the hook matcher are policed** — `Write`, `Edit`, `MultiEdit`,
  `NotebookEdit` and `Bash`, named exactly rather than `*`. `Read`, `Grep` and `Glob` are
  a large share of all tool calls and can never be denied, so they never pay the cost; an
  MCP server that writes files is not in the matcher either.
- The hook **fails open**: if Whiska is not installed it complains on stderr and allows
  the call, rather than denying every tool call in the session.

## How a question reaches you

1. **A mouse is minted** on its first edit or shell call inside a worktree — an opaque
   `mouse_id` written to `.whiska-mouse`, and a row in this repo's house at
   `<main-checkout>/.git/whiska/whiska.db`.
2. **A finished turn hits the doorstep.** The `Stop` hook's whole final message lands in
   `.git/whiska/doorstep/`, one JSON file per entry: written by the owl, which the hook
   shim asks first over `~/.whiska/hook.sock`, or by the escript when the owl does not
   answer. Whether the owl is running changes how fast it lands, never whether it does.
3. **The owl collects**, when herdr reports that mouse's pane idle, when a house opens,
   and on a slow backstop timer. Entries are renamed, never deleted.
4. **Each entry becomes a question**, classified by an invisible marker the mouse ends its
   message on: needs a decision, finished, or no marker at all — which is delivered too,
   because forgetting it should make noise rather than silence.
5. **Delivery is a queue.** One question goes to your main session when herdr says the
   pane is `claude` + `idle`, nothing else is already out waiting, and you are not
   mid-draft. The rest queue silently.
6. **You answer by id.** `whiska reply 12` types into that mouse's pane and closes #12. A
   newer question from the same mouse supersedes its earlier ones, so a mouse that moved
   on cannot wedge the queue.

Nothing on a worktree is ever touched, and nothing is ever deleted.

See [`docs/architecture/`](docs/architecture/) for C4 diagrams of all of this, including
two end-to-end flows.

## What is built, and what is not

Pre-1.0 (`v0.0.1`). The core loop works end to end.

**Built:** mouse identity, per-repo houses, worktree containment and sniff mode, the
doorstep and collection, delivery with its queue, `reply` / `close` / `questions` /
`waiting` / `jump`, the tab bar line and each mouse's sidebar line, the doctor, launchd and
systemd supervision, `init` and `init --global`, the finishing pipeline a mouse runs before
it reports done, and the owl's two sockets in `~/.whiska/`: `owl.sock`, read-only, for
your own scripts and herdr's tab bar, and `hook.sock`, which every hook asks before
starting the escript.

**Not yet:** the per-repo socket and `whiska stop` for a single house, `whiska reopen`,
push approval, and Linux.

## What `whiska init` writes

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
- **The shim asks the owl first** (ADR-0033). It sends the hook's name, a few
  environment variables and the payload to `~/.whiska/hook.sock` with `nc -U`, and the
  owl runs the same hook code the escript would — about 16 ms instead of 245. Anything
  short of an answer within two seconds — no owl, no `nc`, an owl that is hung — and the
  shim carries on to the escript below, so a dead owl only makes hooks slower.
  `WHISKA_HOOK_SOCKET` points it at another socket.
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
  boot. With the owl answering, bash starting is about 2 ms of a 16 ms hook, and the shim
  is what let the hooks move onto the owl with `settings.json` untouched (ADR-0033).

## The `CLAUDE.md` block

`whiska init` also writes the worktree protocol into the repo's own `CLAUDE.md`
(ADR-0045) and installs the skills that drive it — `spawn-worktree`, `send-to-worktree`
and `drop-worktree` (ADR-0046), `whiska-finish`, which holds the finishing pipeline
the block only points at (ADR-0055), `whiska-spec`, which a mouse runs after grilling, and
the person's own `grilling` skill
(ADR-0076). The block is rules, not prose: an imperative or a
concrete fact per line, with the reasoning left in these ADRs. It is a nest of named
markers, one pair per part:

```markdown
<!-- whiska:start -->
<!-- whiska:worktrees:start -->   …the decision tree: route into a running mouse, or spawn
<!-- whiska:marker:start -->      …the worktree-status marker a mouse ends every turn with
<!-- whiska:delivery:start -->    …how its question reaches you, and why you never read its pane
<!-- whiska:report:start -->      …the shape of the message it leaves you
<!-- whiska:finish:start -->      …the trigger for the finishing pipeline, which lives in a skill
<!-- whiska:end -->
```

Re-running `init` replaces each part where it stands, adds one whose markers are missing,
and returns everything outside the outer pair byte for byte — your own text included, and
your own prose sitting between two parts. To make a part yours for good, put `keep` on
its start marker (`<!-- whiska:marker:start keep -->`); Whiska then never rewrites it.
Empty it as well, and the part is dropped for good.

`whiska init` also installs the `/whiska-questions` slash command (ADR-0022).

## The global install

Someone else's repo, or one whose owners will not take another tool's hooks, cannot have
a committed `.claude/` — and an uncommitted file is in no worktree git creates, so every
branch session there starts with none of the rules. `whiska init --global` writes the same
install into `~/.claude` instead, once, for every repo on the machine (ADR-0056):

```
whiska init --global
```

Nothing else is needed per repo. The hooks work out for themselves which worktree they are
firing in — so a repo needs only its house and, if you want one, a `## Finish` heading in
its own `CLAUDE.md`.

A repo that has run `whiska init` keeps winning: its own hooks, block and skills are the
ones in force, and the global copy stands down there. To hand a repo over to the global
install instead:

```
cd your-repo
whiska uninstall
git add -A .claude CLAUDE.md && git commit -m "chore: whiska is installed globally now"
```

`whiska uninstall --global` is the same against `~/.claude`. Neither touches the house —
its mice, its questions and its doorstep are all still there — and neither touches a part
you claimed with `keep`. If `~/.claude/CLAUDE.md` or `~/.claude/settings.json` is a symlink
into a dotfiles repo, every write goes through the link and changes the target in place;
`init --global` prints where each change landed so you can commit it there.

## Keeping the owl awake

```
whiska owl install    # write the owl's job for launchd or systemd, and start it
whiska owl stop       # ask the owl to exit; it returns on `whiska owl start`, or when the service manager next starts your session
whiska owl start      # start it now
whiska owl uninstall  # unload the job and remove it; the log and the record stay
```

The job is the platform's own: a user LaunchAgent,
`~/Library/LaunchAgents/com.whiska.owl.plist`, on macOS, and a systemd user unit,
`~/.config/systemd/user/whiska-owl.service`, on Linux
(ADR-0077). Either starts the owl at login
and restarts it if it crashes — only on a crash, so `whiska owl stop` is a clean exit that
stays stopped (ADR-0040). The job runs
`~/.whiska/owl.sh`, a wrapper generated from the same shell the hook shim uses, so the
binary and the Erlang runtime are found at every launch rather than baked in; stdout and
stderr go to `~/.whiska/owl.log`. `HERDR_SOCKET_PATH` and the `WHISKA_*` overrides are
copied into the job from the shell you install from, so install from a herdr pane; with
nothing to copy the owl falls back to herdr's default socket.

On Linux, systemd stops the owl when your last session ends unless lingering is on;
`whiska owl install` prints `loginctl enable-linger` rather than running it, and the
doctor's `logout` line warns while it is off. Where this user has no systemd at all —
most containers — `install` refuses and says to run `whiska owl` in a pane.

The service manager starts the owl with no arguments, so it opens exactly the houses in its record
(`~/.whiska/houses`, ADR-0039). With the record empty it idles and waits; `whiska owl
<repo>` in the foreground is how a house first gets recorded — Ctrl-C it afterwards and
the supervised owl picks it up on `whiska owl start`.

Two owls would collect the same doorsteps, so `install` refuses while any owl is in the
process table and prints the handover (Ctrl-C the foreground one, install again), and the
foreground `whiska owl` refuses while the supervised owl is running — unless it *is* that
owl, which it tells by pid (ADR-0040's 2026-09-28 note). `whiska stop` is not the
owl's stop: it shuts one house (ADR-0003) and is not built until the owl has a per-repo
socket.

## The owl, the house, the doorstep

```
whiska owl            # run the owl in the foreground, house open for this repo
whiska owl ~/a ~/b    # ...or for each repo named (a worktree path names its repo)
```

When a mouse finishes a turn, its `Stop` hook (installed by `whiska init`) leaves the
whole final message on the repo's **doorstep** —
`<main-checkout>/.git/whiska/doorstep/`, one JSON file per entry, stamped with `mouse_id`,
branch and time. The shim asks the owl first, over `~/.whiska/hook.sock`, and the owl
writes the entry and collects it at once; when the owl does not answer, `whiska hook stop`
writes the same entry. Either way the question reaches the doorstep, so whether the owl is
running changes nothing about what the mouse does (ADR-0036, amended).

The owl **collects** the doorstep when it wrote an entry itself, when herdr reports that
mouse's pane idle, when a house opens, and on a slow backstop timer. Each entry becomes a question, classified by its
marker alone (ADR-0009), an invisible line the mouse ends on: needs-decision → open;
`done` → open too,
delivered as "finished" with no reply offered, and closed once the person writes something after it (ADR-0008, note of 2026-10-08); no marker
→ `unmarked`, and open — forgetting the marker makes noise rather than silence. An entry whose worktree is gone is recorded as `orphaned`. Collected entries are
renamed `.collected`, never deleted (ADR-0007), so `ls *.json` on the doorstep is exactly
what is still waiting.

The house finds each mouse's herdr pane by its `cwd`, records it, and subscribes to that
pane's status changes; a pane that closes or exits marks its mouse dead and orphans its
open questions (ADR-0026). Nothing on disk is ever touched.

herdr is the one boundary with a fake behind it in tests (`Whiska.Herdr`, ADR-0031); the
real client is checked against an in-test server speaking herdr's wire protocol.

## Delivery, in detail

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

## Wiring the tab bar and the sidebar

Neither repeats the other (ADR-0048). Facts about the whole machine go on herdr's tab
bar, once, one thing named and several counted (ADR-0027). What each mouse is doing goes
in herdr's sidebar, under that mouse's own workspace
(ADR-0082). Both are rows in your own herdr
config, which Whiska never writes; `whiska doctor` prints each.

### The machine-wide line, on herdr's tab bar

The owl's state is always there, so a blank tab bar entry never passes for a working
Whiska:

```
🦉 watching
🦉 watching · 🐱 myrepo · ⌃a space
🦉 watching · away · 🐱 2 whiskas · ⌃a space
🦉 owl down
```

`whiska owl install` writes the script herdr runs, `~/.whiska/herdr-status.sh`, and
prints the entry that runs it. The script starts nothing: it asks the owl for the line
over `~/.whiska/owl.sock` with `nc -U` (ADR-0025). Its one argument is the key you bound
to reach what is waiting, written the way you want it shown; the owl adds it only when
something not held is waiting, and with no argument there is no hint. Whiska never reads
your herdr keybindings. That entry is yours — herdr's config is machine-global and
hand-edited, so Whiska never writes it. Paste it into `~/.config/herdr/config.toml`,
commit it with your dotfiles, and `herdr server reload-config`. `whiska owl install` prints
it with your own path already filled in; `~/.whiska/herdr-status.sh` works too, since herdr
runs a command entry through a login shell:

```toml
[ui]
tab_bar_right = [
  { type = "command", command = "/Users/you/.whiska/herdr-status.sh '⌃a space'", interval_seconds = 5, timeout_seconds = 2 },
]
tab_bar_right_separator = " · "
```

`whiska doctor` says whether it took.

`🦉 watching` means the owl answered and is collecting; `🦉 owl down` means nothing
answered on its socket within a second — no owl, a crashed one, a hung one — or it
answered with doorstep entries sat uncollected past its backstop. `🦉 nc missing` and
`🦉 nc cannot reach the owl` say the tool is the problem, not the owl. `🐱` is what is
waiting anywhere on this machine, the same reading `whiska waiting` prints: one whiska is
named by its repo, several become a count. `whiska statusline` prints the same line
without the owl, finding it in the process table the way `whiska doctor` does.

### Each mouse's line, in herdr's sidebar

The owl reports a line under each mouse's workspace (herdr 0.9 or newer), and one under
the main checkout's for what is true of the whole repo:

```
myrepo
  ⏳ gated: you're typing
feat/quiet-marker
  🐭 #52 · waiting on you · 4m
  sqlite or a plain file?
fix/doctor-probe
  ⚠ stuck 6m
  Bash mix test
feat/cache-ttl
  ⏳ queued behind #52
  which cache TTL?
feat/watch-board
  ◐ A board the owl writes
```

The first line is the state, starting with a symbol; up to two more carry the question,
wrapped at 31 characters. In the order they sort: `🐭` waiting on you (sent, with how
long; or next to go), `✅` finished, `⚠ stuck` (blocked, or working and silent for two
minutes, with the tool call it is in), `⏳ queued behind #n`, `🎯`/`💤` waiting behind a
focus or away, `⏸` held, `↩ picked up`, `◐` working — its spinner turns once a second, so a
still one means the owl stopped — and `✖ no pane`, `⚠ many panes`, `? herdr can't say`. An
idle mouse with nothing to report has no line. The main checkout's line says when no main
session is recorded, why delivery is gated, how many questions wait with no line of their
own, and what dead branches left behind (`◌ 2 orphaned (feat-gone, fix-x)`).

The mice re-sort only when one starts or stops needing you — waiting or finished — so rows
do not jump under your cursor, and your own drag order stands otherwise. Each line expires
thirty seconds after it was last sent, so a dead owl's lines go away rather than lie, and
the owl sends them all again within two seconds of herdr restarting, which drops them.

The colours are yours: each line is coloured by its first symbol, which only Whiska writes,
so a mouse whose topic says "waiting" never turns orange. `whiska doctor` prints these rows
until your config has them; paste them into `~/.config/herdr/config.toml` and
`herdr server reload-config`:

```toml
[ui.sidebar.spaces]
rows = [
  ["state_icon", { token = "workspace", fg = "#586e75", dim = false }],
  ["branch", "git_status"],
  [{ token = "$whiska", fg = "#657b83", dim = false, rules = [
    { starts_with = "🐭", fg = "#cb4b16" },
    { starts_with = "⚠", fg = "#dc322f" },
    # … one rule per symbol; `whiska doctor` prints all fourteen
  ] }],
  [{ token = "$whiska_q", fg = "#93a1a1" }],
  [{ token = "$whiska_q2", fg = "#93a1a1" }],
]
```

`whiska watch` prints the same lines, worked out on the spot, when the sidebar looks wrong.

Whiska no longer writes a Claude Code statusline. `whiska init` takes out the one an older
init wrote — the script, its `statusLine` entry, and, for `init --global`, puts back the
line it had displaced. Until then an old script draws only your own line.

## A full `whiska doctor` run

```
whiska doctor         # from the main checkout or any worktree of it
```

Delivery only happens when the owl is up and a main session is recorded and idle, and
the tab bar only tells you whether the owl is watching. From
the main terminal a broken pipe and a quiet fleet look much the same. The
doctor is what you run when the mice have gone quiet, to learn which silence you are in
(ADR-0038) — including the silence of something that is up and running code you have
already replaced, which is what the next section is about. It checks this repo's
prerequisites (binary, runtime, herdr, owl), its hooks
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
  warn  build       ./whiska here was built 1 h 0 min after /Users/me/.local/bin/whiska was installed — nothing runs this build until it is copied over
                    fix: cp whiska /Users/me/.local/bin/whiska
  ok    runtime     /Users/me/.asdf/installs/erlang/28.1.1/bin/escript
  ok    herdr       reachable at /Users/me/.config/herdr/herdr.sock (12 panes)
  ok    herdr version  0.9.3
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
  ok    session wiring  not checked — herdr did not name the main session, or its transcript is gone
  ok    questions   none waiting
  ok    mice        feat-thing: live pane w1:p3

1 failed, 6 warnings.
```

## A change is not live until the thing running it is restarted

Three pieces of this run from a copy taken when they started, and keep running it until
something restarts them. Each one has looked fine for hours while serving code that was
already replaced, so the doctor checks all three by age rather than by liveness.

- **The owl holds the binary it started with.** `cp whiska ~/.local/bin/whiska` replaces
  the file; the running owl is unaffected and the board keeps drawing the old behaviour.
  `whiska owl stop && whiska owl start`. The doctor's `owl` line compares the process
  against the binary's mtime and says so.
- **Nothing runs an escript you built but did not install.** The hooks, the statusline and
  the owl all run the binary on PATH. `mix escript.build` alone changes nothing. The
  `build` line compares `./whiska` in the checkout with the installed copy.
- **A Claude Code session reads its settings once, at startup.** A session that began
  before `whiska init` changed the wiring is running the wiring from before it, and
  nothing in that session ever says so — restart Claude in that pane. The `session wiring`
  line compares when the main session started against when the settings files it loads
  last changed: `.claude/settings.json` and `~/.claude/settings.json`, each with the
  `.local` one beside it. The session's age is the creation time of its own transcript
  file, not the first timestamp inside it — a resumed session is a new process that read
  the settings afresh, but Claude Code copies the previous session's entries into the new
  transcript, timestamps and all, so the entries would age a session that had just been
  restarted at hours old. The line says only what the clock knows: that a settings file
  changed after the session started. It does not claim the hooks in it changed — a model,
  a permission or an MCP server moves that mtime exactly as a hook does. Only the settings
  files are compared: the shim and the statusline script are executed afresh every time,
  so a change to either is live the moment it lands.

`whiska init` leaves a file alone when what it would write is already there, mtime
included — otherwise a harmless re-init would make every live session look stale. The
repo's statusline script is the fourth of these and is versioned rather than timed
(ADR-0059): the stamp in the copy on disk against the one this build ships.

## Cold start

Measured on the development machine (Apple silicon, macOS 25.4, OTP 28, Elixir 1.19),
30 runs each:

| What runs | Per invocation |
|---|---|
| Bare `elixir -e ':ok'` | 177 ms |
| `whiska --version` — escript boot floor | 126 ms |
| **`whiska hook pre-tool-use` — the real job, SQLite included** | **~220 ms** |
| First run ever, which also unpacks the bundled SQLite library | 627 ms, once |
| **The hook shim with the owl answering** (ADR-0033, measured 2026-10-07) | **~16 ms** |

Roughly 126 ms of the escript's time is the BEAM booting before any code runs, and the
rest is loading Ecto, db_connection and exqlite. The SQLite work itself — open, migrate,
upsert — is under 2 ms. Nothing inside the program can remove the first 126 ms, which is
why every hook asks the already-running owl first, and why the narrow matcher above
matters more than it looks: `Read`, `Grep` and `Glob` never pay anything.

## Why the binary is 3 MB

An escript is a zip archive. It carries no `priv/` directories, and native code cannot be
`dlopen`ed out of a zip in any case — so SQLite's 1.6 MB native library travels as bytes
embedded in `Whiska.BundledNIF` and is unpacked to `~/.cache/whiska/exqlite-<vsn>/` on
first run. That is the only reason ADR-0030's "single binary" and ADR-0028's "real
SQLite" can both hold. It stays: the escript is every command, and what every hook falls
back on when the owl does not answer (ADR-0033).
