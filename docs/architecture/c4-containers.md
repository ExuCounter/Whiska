# Container Diagram — Whiska

Level 2. The deployable and storable pieces.

**Read the two boundaries as a timeline.** Everything in *built* exists and is tested
today (596 tests). Everything in *designed, not built* is decided in the ADRs and has no
code yet.

```mermaid
C4Container
  title Container Diagram - Whiska

  Person(person, "The person", "Answers one question at a time")
  System_Ext(herdr, "herdr", "Panes, sessions, agent status")

  Container_Boundary(built, "Built") {
    Container(shim, "whiska.sh", "bash", "Committed hook shim; resolves runtime at fire time, fails open")
    Container(statusline, "whiska-statusline.sh", "bash", "Committed statusline; runs the global one, appends whiska statusline")
    Container(cli, "whiska", "Elixir escript", "Hooks, init, mode - and boots the owl")
    Container(owl, "Owl", "Elixir/OTP supervisor", "One per machine; one supervised house per open project")
    Container(house, "House", "GenServer per project", "Herdr subscription, pane discovery, collection, delivery to the main session")
    Container(doorstep, "Doorstep", "directory, .git/whiska/doorstep/", "JSON entries a Stop hook left, renamed .collected once read")
    ContainerDb(db, "House database", "SQLite, .git/whiska/whiska.db", "Mouse records and questions, one per repo")
    Container(marker, "Mouse marker", ".whiska-mouse file", "The opaque mouse_id at the worktree root")
    Container(backstop, "Backstop mark", "text file, .git/whiska/backstop", "How much the backstop collected that the idle trigger missed, and when")
    Container(record, "Open-houses record", "text file, ~/.whiska/houses", "One main checkout per line; which houses the owl has open")
    Container(svc, "LaunchAgent", "launchd, com.whiska.owl", "Starts the owl at login, restarts a crash; runs the owl.sh wrapper")
  }

  Container_Boundary(todo, "Designed, not built") {
    Container(sockets, "Sockets", "Unix, per-repo and global", "Push approval, mouse identity, cross-repo reads")
  }

  Rel(person, cli, "Runs whiska init / mode / owl / questions")
  Rel(statusline, cli, "Runs whiska statusline on every refresh", "JSON on stdin")
  Rel(cli, db, "questions and statusline read the house")
  Rel(cli, doorstep, "questions and statusline count what is uncollected")
  Rel(cli, herdr, "mice and statusline list panes")
  Rel(cli, record, "owl reopens from it; statusline and doctor read it while an owl is alive")
  Rel(herdr, shim, "PreToolUse and Stop fire in a mouse's session")
  Rel(shim, cli, "Execs with the payload on stdin", "JSON")
  Rel(cli, marker, "Reads, minting one on first use")
  Rel(cli, doorstep, "Stop hook writes one entry, unconditionally")
  Rel(cli, owl, "whiska owl boots it in the foreground")
  Rel(cli, svc, "whiska owl install / stop / start / uninstall", "launchctl")
  Rel(svc, owl, "Runs whiska owl with no arguments; KeepAlive on crash only")
  Rel(owl, house, "Opens one per project, supervised independently")
  Rel(owl, record, "Adds a house when opened, removes it when shut")
  Rel(house, herdr, "Subscribes per mouse pane; lists panes to find them")
  Rel(house, doorstep, "Collects on idle, at open, and on a backstop")
  Rel(house, backstop, "Marks what the backstop collected; clears it at open")
  Rel(cli, backstop, "doctor reads it: has the last resort been doing the trigger's job")
  Rel(house, db, "Records questions and marks mice dead; reads the next open one")
  Rel(house, herdr, "Types one question at a time into the main session when idle")

  UpdateLayoutConfig($c4ShapeInRow="4", $c4BoundaryInRow="1")
```

## Why each piece is its own container

**`whiska-statusline.sh` is the second committed script** (ADR-0027). A project-level
`statusLine` replaces the global one, so the script runs the global command first and
appends the line `whiska statusline` prints: the owl's state, always, so a blank line
never passes for a working Whiska; the whiskas on the machine when there is more than
one; the mice here; the questions here; and the whiskas elsewhere with something waiting
— the whiskas and mice from herdr's pane list and a direct read of each other house
(ADR-0025 addendum), the owl from the process table. It shares the shim's binary-and-runtime
lookup, generated from the same source, so the two cannot drift. Claude Code sets no
`CLAUDE_PROJECT_DIR` for statusline commands, so the committed command falls back to a
path relative to the project directory.

**The open-houses record is the one machine-level file** (ADR-0039). It sits in
`~/.whiska/`, the folder ADR-0025 reserves for the global socket, and says which houses
the owl has open — not which exist (ADR-0003). The owl writes it as it opens and shuts
houses and leaves it behind when it stops, so `whiska owl` with no arguments reopens the
same houses. The statusline and the doctor read it to know what counts as a whiska, but
only while an owl is in the process table: a file a dead owl left says nothing.

**The backstop mark is a house's file, not a machine-level one** (ADR-0036, note of
2026-09-28). Everything the backstop collects is something herdr's idle event should have
brought a minute earlier, so the house warns as it happens and leaves a count and a
timestamp beside the doorstep; `whiska doctor` turns that into one line. It is per house
because the fact is one house's and the doctor is scoped to one repo — and because
per-house files mean no two houses ever rewrite the same one. The owl clears it when it
opens the house, so the mark is always about the run happening now.

**`whiska.sh` is separate from the binary on purpose** (ADR-0035). The committed
`settings.json` names only the shim — now with a subcommand argument, `pre-tool-use` or
`stop` — so nothing machine-specific reaches a shared repo. The shim resolves the runtime
when the hook fires, so an Erlang upgrade needs no re-`init`.

**The house database lives under the main checkout's `.git/`**, which every worktree
shares. That is what puts all of a repo's mice in one house instead of one per worktree,
and it is gitignored by construction. Storage is real SQLite, not flat files (ADR-0028).

**The doorstep is a directory, not a socket** (ADR-0036). The `Stop` hook writes a file
and exits — unconditionally, whether or not the owl is running. "The owl is down" is
therefore not a case: there is no fallback path because there is no primary path to fall
back from. Entries are written to a temp name and renamed into place, so the owl never
reads a half-written file; collected ones are renamed `.collected` rather than deleted
(ADR-0007), which means `ls *.json` on the doorstep is exactly what is still waiting —
answerable with no database and no owl.

**It sits in the house, not the worktree**, so an ordinary `drop-worktree` cannot silently
erase pending questions. The mirror cost is that a question can outlive its mouse; that
state has a name already (ADR-0026) rather than being a new problem.

**The LaunchAgent is the one supervisor** (ADR-0040). It runs `~/.whiska/owl.sh`, not the
escript: launchd's `PATH` cannot find `escript`, and the wrapper is generated from the same
fragments as the hook shim, so the runtime is found at every launch and an Erlang upgrade
needs no reinstall. `KeepAlive` is on crash only, which is what lets `whiska owl stop` be a
clean exit that stays stopped without booting the job out. `whiska stop` is a different,
per-house verb (ADR-0003) and waits for the socket.

**One owl, many houses** (ADR-0001). An earlier draft gave each repo its own OS process;
that fought launchd and made "what is waiting on me anywhere" a new subsystem. Each house
is supervised independently, so one project's house crashing is invisible to every other.

**Delivery lives in the house, and nothing lives across houses** (ADR-0008, ADR-0044).
Each house owns its own idle-gated queue to its own main session, and that is the only
place Whiska ever types. Telling another repo's idle session that something is waiting
here is the statusline's job, not the owl's: a `refreshInterval` on the statusLine
command re-runs the script every 15 seconds, and it reads the other houses off disk. The
Nudge process that once typed into other sessions is deleted.

**herdr is the one boundary with a fake behind it** (ADR-0031). `Whiska.Herdr` is a
behaviour; `Whiska.Herdr.Socket` is the real client and tests use a Mox fake, checked
against an in-test server speaking herdr's own wire protocol. Everything downstream —
collection, classification — is plain code with nothing mocked.

## What is still designed only

The per-repo and global sockets with the peer-PID check (ADR-0024, ADR-0025);
`whiska stop` for one house; push approval; cross-repo commands.
