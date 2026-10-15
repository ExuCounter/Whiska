# Deployment — one machine

Everything runs on the person's own laptop as one OS user. There is no server. The owl
leaves the machine for two things: while a merge request waits it fetches a base branch
from its remote (ADR-0087), and on GitLab it reads a request, or looks one up for a
pushed branch, through the person's `glab` (ADR-0060). Every endpoint Whiska
serves is a Unix socket or a file.

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
      ContainerDb(housedb, "whiska.db", "SQLite, .git/whiska/", "Mice, questions, each turn's usage and letters from other houses")
      Container(houseletters, "letters/", "directory, .git/whiska/", "Letters another repo's main session left, kept, owner only")
      Container(doorstep, "doorstep/", "directory, .git/whiska/", "Uncollected questions")
      Container(sock, "repo socket - NOT BUILT", "Unix socket, .git/whiska/", "Push approval, mouse identity")
      Container(markerf, ".whiska-mouse", "file, worktree root", "The opaque mouse_id")
      Container(briefs, "Briefs", "main.md in .git/whiska/, .whiska-brief.md at a worktree root", "Everything Whiska tells each session")
      Container(denylist, ".whiska-settings.json", "file, worktree root", "The deny list a shaped mouse starts with")
    }
    Deployment_Node(home, "Home directory", "~") {
      Container(globalsock, "owl.sock", "Unix socket, ~/.whiska/", "Read-only, cross-repo: waiting, show, jump, questions, the tab bar line")
      Container(hooksock, "hook.sock", "Unix socket, ~/.whiska/", "Private: the hook shim asks it before the escript, and whiska start asks it to open a house")
      Container(tabbar, "herdr-status.sh", "bash, ~/.whiska/", "herdr's tab bar runs it; asks owl.sock with nc")
      Container(plist, "The owl's job", "~/Library/LaunchAgents/ or ~/.config/systemd/user/", "The plist or the unit: runs owl.sh, restarts on a crash only")
      Container(wrapper, "owl.sh + owl.log", "~/.whiska/", "Resolves binary and runtime at launch; the owl's stdout and stderr")
      Container(cache, "exqlite cache", "~/.cache/whiska/", "Unpacked SQLite native library")
      Container(globalinstall, "Global install - optional", "~/.claude/", "The same shim and three hooks, for every repo. Often symlinks into a dotfiles repo")
    }
  }
  Deployment_Node(forge, "The forge", "off this machine") {
    Container(remote, "Git remote", "git over https or ssh", "The base branch a merge request is merged into")
    Container(forgeapi, "Forge API", "https", "A merge request's state, pipeline and threads")
  }

  Rel(plist, wrapper, "The service manager runs the wrapper, which execs the owl")
  Rel(owl, housedb, "Holds open per open house")
  Rel(owl, doorstep, "Collects on an idle signal")
  Rel(owl, sock, "Listens, one per open house")
  Rel(owl, globalsock, "Listens, one per machine")
  Rel(owl, hooksock, "Listens, one per machine")
  Rel(owl, remote, "Fetches the base alone every minute while a merge request waits, and a dropped branch for a review mouse, never prompting", "git fetch")
  Rel(owl, forgeapi, "Reads a recorded GitLab merge request every minute, and looks one up by a pushed branch, GET only", "glab api")
  Rel(mousepane, globalinstall, "Runs its hooks where the repo wires none")
  Rel(mousepane, hooksock, "Every hook asks the owl first, with nc")
  Rel(mousepane, doorstep, "Stop hook writes an entry when the owl does not answer")
  Rel(owl, doorstep, "Writes the entry a hook sent it, then collects")
  Rel(mousepane, housedb, "UserPromptSubmit hook takes a saved answer and stamps it")
  Rel(mousepane, markerf, "Hook reads or mints")
  Rel(mainpane, briefs, "Claude Code starts with its brief, as do the mice")
  Rel(mainpane, houseletters, "whiska tell, on the person's word, copies a letter into another open repo's folder and records it in that repo's whiska.db")
  Rel(owl, houseletters, "Types a letter's path into its own main session, under away and the gate")
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
