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
      Container(globalsock, "owl.sock", "Unix socket, ~/.whiska/", "Read-only, cross-repo: waiting, show, the tab bar line")
      Container(hooksock, "hook.sock", "Unix socket, ~/.whiska/", "Private: the hook shim asks it before the escript")
      Container(tabbar, "herdr-status.sh", "bash, ~/.whiska/", "herdr's tab bar runs it; asks owl.sock with nc")
      Container(plist, "The owl's job", "~/Library/LaunchAgents/ or ~/.config/systemd/user/", "The plist or the unit: runs owl.sh, restarts on a crash only")
      Container(wrapper, "owl.sh + owl.log", "~/.whiska/", "Resolves binary and runtime at launch; the owl's stdout and stderr")
      Container(cache, "exqlite cache", "~/.cache/whiska/", "Unpacked SQLite native library")
      Container(globalinstall, "Global install - optional", "~/.claude/", "The same shim, four hooks and skills, for every repo. Often symlinks into a dotfiles repo")
    }
  }

  Rel(plist, wrapper, "The service manager runs the wrapper, which execs the owl")
  Rel(owl, housedb, "Holds open per open house")
  Rel(owl, doorstep, "Collects on an idle signal")
  Rel(owl, sock, "Listens, one per open house")
  Rel(owl, globalsock, "Listens, one per machine")
  Rel(owl, hooksock, "Listens, one per machine")
  Rel(mousepane, globalinstall, "Runs its hooks where the repo wires none")
  Rel(mousepane, hooksock, "Every hook asks the owl first, with nc")
  Rel(mousepane, doorstep, "Stop hook writes an entry when the owl does not answer")
  Rel(owl, doorstep, "Writes the entry a hook sent it, then collects")
  Rel(mousepane, housedb, "UserPromptSubmit hook takes a saved answer and stamps it")
  Rel(mousepane, markerf, "Hook reads or mints")
  Rel(tabbar, globalsock, "Asks for the line every five seconds")

  UpdateLayoutConfig($c4ShapeInRow="3", $c4BoundaryInRow="1")
```

## What the placement buys

Sockets under a repo's own `.git/` are the security property: a rogue process cannot
guess a shared port, it has to already be inside the repo (ADR-0024, ADR-0001). The two
sockets in `~/.whiska/` are deliberately weaker, one read-only and one trusting its caller
as the escript trusts stdin, and they sit in the home so no socket path passes macOS's
104-byte cap (ADR-0033). `~/.cache/whiska/` exists because an escript is a zip and native
code must be unpacked before it can be loaded. `~/.claude/` is the second place the same
install can live, for a repo that cannot carry a committed `.claude/`; its paths are often
symlinks into a dotfiles repo, so every write goes through the link (ADR-0056). The owl's
job is in the user's own service-manager domain and runs the wrapper because neither
manager's `PATH` finds `escript`; under systemd the owl stops with the person's last
session unless lingering is on (ADR-0040).

Not built: the repo socket, drawn because its placement is the security argument, and
`whiska stop` for one house.
