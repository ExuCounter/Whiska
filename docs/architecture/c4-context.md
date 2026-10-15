# System Context — Whiska

Level 1. Who and what Whiska sits between.

Whiska tracks Claude Code sessions ("mice") working in isolated git worktrees. It
does not run Claude Code itself and it does not manage terminals — herdr does both
(ADR-0020). Whiska's job is identity, rules, each session's brief
(ADR-0088), and getting a mouse's question in front of the person
exactly once.

```mermaid
C4Context
  title System Context - Whiska

  Person(person, "The person", "Works several projects at once, one main session per project")

  System(whiska, "Whiska", "Mints mouse identity, enforces hard rules, queues questions to the main session")

  System_Ext(claude, "Claude Code", "Main session and mice, each started with its brief; fires PreToolUse, Stop and UserPromptSubmit hooks")
  System_Ext(herdr, "herdr", "Terminal multiplexer - owns panes, starts Claude, reports agent status")
  System_Ext(git, "git worktrees", "One worktree per mouse, laid out under the main checkout")
  System_Ext(launchd, "Service manager", "launchd on macOS, systemd on Linux - keeps the one owl per machine running")
  System_Ext(nc, "Desktop notifications", "terminal-notifier or osascript on macOS, notify-send on Linux")
  System_Ext(remote, "Git remote", "The forge's copy of the repo, where a merge request is merged")
  System_Ext(forge, "Forge API", "GitLab or GitHub: a merge request's state, pipeline and threads")

  Rel(person, claude, "Types into the main session")
  Rel(claude, whiska, "Sends hook events; the shim hands them to the owl over its socket", "JSON on stdin, nc -U")
  Rel(whiska, claude, "Writes each session's brief, denies a tool call, rings a mouse's doorbell, hands it the saved answer as context")
  Rel(whiska, herdr, "Reads agent status and screens, creates worktrees and starts Claude in them, types into panes, closes a landed or dropped mouse's pane", "herdr's Unix socket, JSON lines")
  Rel(herdr, claude, "Starts and hosts every session")
  Rel(herdr, whiska, "Tab bar asks the owl for its line every five seconds", "nc -U")
  Rel(whiska, git, "Derives layout from, stores house under .git/, removes a landed worktree")
  Rel(launchd, whiska, "Starts the owl at login, restarts it on a crash")
  Rel(whiska, nc, "Raises every hoot; a click on it jumps to the main session")
  Rel(whiska, remote, "Fetches the base every minute while a merge request waits, and a dropped branch for a review mouse; pr pushes a branch", "git")
  Rel(whiska, forge, "Reads a recorded GitLab merge request every minute, GET only; pr opens one", "glab or gh, the person's login")

  UpdateLayoutConfig($c4ShapeInRow="3", $c4BoundaryInRow="1")
```

## The actors worth naming

- **The person** never talks to Whiska's storage directly. They type into a main session
  and answer one question at a time.
- **herdr is unchanged by this project** (ADR-0020). A mouse is not a new runtime thing —
  it is a name for a herdr pane running Claude Code. This is also the one boundary where
  mocking is allowed in tests (ADR-0031).
- **git is asked, and now also answered to.** Whether a branch has landed is a local git
  question, and it is the one that lets the owl take a landed worktree down by itself
  (ADR-0061). No forge and no credentials of Whiska's are involved in it. While a merge
  request waits, the owl fetches the base, so a merge on the forge reads as landed
  (ADR-0087).
- **The forge is read, never written by the owl.** A recorded GitLab merge request is read
  every minute through the person's own `glab` login, by one runner that builds only a
  `GET` (ADR-0060). Whiska holds no token. `whiska pr` opens the request through the same
  login, on the person's word (ADR-0085).
- **The service manager** matters because there is exactly one owl per machine, not one
  process per repo (ADR-0001). `whiska owl install` writes the user LaunchAgent
  `com.whiska.owl` on macOS, or the systemd user unit `whiska-owl.service` on Linux, which
  starts the owl at login and restarts it if it crashes (ADR-0040). The foreground `whiska owl`
  still exists, and refuses while the supervised owl is running.
