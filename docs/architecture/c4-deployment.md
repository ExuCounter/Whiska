# Deployment — one machine

Everything runs on the person's own laptop as one OS user. There is no server and no
network hop; every endpoint is a Unix socket or a file.

```mermaid
C4Deployment
  title Deployment Diagram - developer machine
  Deployment_Node(mac, "Developer machine", "macOS or Linux, single OS user") {
    Deployment_Node(launchd, "Service manager, user domain", "launchd com.whiska.owl, or systemd whiska-owl.service") {
      Container(owl, "Owl", "Elixir/OTP", "One per machine; every open house inside it. Started at login, restarted on a crash")
    }
    Deployment_Node(herdrnode, "herdr", "terminal multiplexer") {
      Container(mainpane, "Main session pane", "Claude Code", "One per project")
      Container(mousepane, "Mouse panes", "Claude Code", "One per worktree")
    }
    Deployment_Node(repo, "Repo on disk", "main checkout + worktrees/") {
      ContainerDb(housedb, "whiska.db", "SQLite, .git/whiska/", "Mice and questions")
      Container(doorstep, "doorstep/", "directory, .git/whiska/", "Uncollected questions")
      Container(sock, "repo socket - NOT BUILT", "Unix socket, .git/whiska/", "Push approval, mouse identity")
      Container(markerf, ".whiska-mouse", "file, worktree root", "The opaque mouse_id")
    }
    Deployment_Node(home, "Home directory", "~") {
      Container(globalsock, "owl.sock - NOT BUILT", "Unix socket, ~/.whiska/", "Read-only, cross-repo")
      Container(plist, "The owl's job", "~/Library/LaunchAgents/ or ~/.config/systemd/user/", "The plist or the unit: runs owl.sh, restarts on a crash only")
      Container(wrapper, "owl.sh + owl.log", "~/.whiska/", "Resolves binary and runtime at launch; the owl's stdout and stderr")
      Container(cache, "exqlite cache", "~/.cache/whiska/", "Unpacked SQLite native library")
      Container(globalinstall, "Global install - optional", "~/.claude/", "The same block, shim, board script, hooks and skills, for every repo. Often symlinks into a dotfiles repo")
    }
  }

  Rel(plist, wrapper, "The service manager runs the wrapper, which execs the owl")
  Rel(owl, housedb, "Holds open per open house")
  Rel(owl, doorstep, "Collects on an idle signal")
  Rel(owl, sock, "Listens, one per open house")
  Rel(owl, globalsock, "Listens, one per machine")
  Rel(mousepane, globalinstall, "Runs its hooks where the repo wires none")
  Rel(mousepane, doorstep, "Stop hook writes an entry")
  Rel(mousepane, markerf, "Hook reads or mints")
  Rel(mainpane, globalsock, "whiska projects / goto")

  UpdateLayoutConfig($c4ShapeInRow="3", $c4BoundaryInRow="1")
```

## What the placement buys

**Sockets under the repo's own `.git/` are the security property** (ADR-0024, ADR-0001).
A rogue process cannot guess a shared port — it has to already be inside a specific repo
to find that repo's socket. That survived the move from one process per repo to one owl,
because one process can listen on many private sockets. On top of that, a request must
present the actual marker-file content (not merely claim an id), and the listening side
asks the kernel for the peer PID (`LOCAL_PEERPID`, unfakeable by the connecting process)
and walks its real parent chain to confirm it descends from the legitimate `claude`
process for that worktree.

Stated honestly: everything runs as the same OS user with no sandboxing. This stops
accidental and casual spoofing, not a determined co-resident attacker. Airtight would
need OS-level isolation, which is out of scope.

**The global socket at `~/.whiska/owl.sock` is deliberately weaker** (ADR-0025). It only
answers read-only "what is open, where", can never approve a push or act on a mouse, so
ordinary file permissions are enough. It is also why `whiska projects` and `whiska goto`
are the only commands that work from anywhere on the machine rather than inside a repo.

**`~/.cache/whiska/` exists only because an escript is a zip.** Native code cannot be
`dlopen`ed out of one, so the bundled SQLite library unpacks there on first run — 627 ms,
once. It disappears with ADR-0033's native hook client.

**`~/.claude/` is the second place the same install can live** (ADR-0056). A repo that
cannot carry a committed `.claude/` — someone else's repo, or one whose owners will not
take another tool's hooks — would otherwise spawn mice with none of the rules, because an
uncommitted file is in no worktree git creates. `whiska init --global` writes the identical
relative paths under `~` instead: the block in `~/.claude/CLAUDE.md`, the shim and the
board script in `~/.claude/hooks/`, both hooks and the statusline in
`~/.claude/settings.json`, and all nine skills in `~/.claude/skills/`. Nothing in the hooks was
ever repo-specific — which worktree they are firing in comes from where the session started
(ADR-0053), and the board file is found by walking up from the session's directory — so the
move costs nothing. What stays in the repo is the house under `.git/whiska`, which was
never committed anyway.

The boundary that moves with it is who wins. Claude Code merges the hook arrays from both
files, so in a repo that wires Whiska itself the global shim exits before resolving
anything: the repo's copy is in force and this one stands down. These paths are also
commonly symlinks into a dotfiles repo, so every write goes through the link and changes
the target in place; replacing the link would disconnect that repo silently.

**The owl's job lives in the user's own service-manager domain** (ADR-0040,
ADR-0077). On macOS it is the LaunchAgent
`com.whiska.owl` in launchd's `gui` domain, at
`~/Library/LaunchAgents/com.whiska.owl.plist`. On Linux it is the systemd user unit
`whiska-owl.service`, at `~/.config/systemd/user/whiska-owl.service`. Either starts the owl
at login and restarts it on a crash. Either runs the wrapper in `~/.whiska/` rather than
the escript, because neither manager's `PATH` can find `escript`, and the wrapper shares
the hook shim's runtime lookup. The owl it starts takes no arguments and opens what the
open-houses record lists. Under systemd, the owl stops when the person's last session ends
unless lingering is on.

**What actually exists today**: `whiska.db`, `.whiska-mouse`, `doorstep/`, the cache, the
open-houses record, the global install, the owl's job (plist or unit) with its wrapper and log, and the
owl itself with its houses and herdr subscription. Not yet: either socket, and `whiska stop` for one house. The
two sockets are drawn because their placement is the security argument above, not because
they are written.
