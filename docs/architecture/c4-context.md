# System Context — Whiska

Level 1. Who and what Whiska sits between.

Whiska coordinates Claude Code sessions ("mice") working in isolated git worktrees. It
does not run Claude Code itself and it does not manage terminals — herdr does both
(ADR-0020). Whiska's job is identity, rules, and getting a mouse's question in front of
the person exactly once.

```mermaid
C4Context
  title System Context - Whiska

  Person(person, "The person", "Works several projects at once, one main session per project")

  System(whiska, "Whiska", "Mints mouse identity, enforces hard rules, queues questions to the main session")

  System_Ext(claude, "Claude Code", "Main session and mice; fires PreToolUse and Stop hooks")
  System_Ext(herdr, "herdr", "Terminal multiplexer - owns panes, starts Claude, reports agent status")
  System_Ext(git, "git worktrees", "One worktree per mouse, laid out under the main checkout")
  System_Ext(launchd, "launchd", "Supervises the one owl per machine as a user LaunchAgent")
  System_Ext(nc, "Desktop notifications", "terminal-notifier, or osascript")

  Rel(person, claude, "Types into the main session")
  Rel(claude, whiska, "Sends hook events", "JSON on stdin / socket")
  Rel(whiska, claude, "Denies a tool call, or types an answer into a mouse")
  Rel(whiska, herdr, "Opens panes, reads agent status, closes a landed mouse's pane", "herdr CLI")
  Rel(herdr, claude, "Starts and hosts every session")
  Rel(whiska, git, "Derives layout from, stores house under .git/, removes a merged worktree")
  Rel(launchd, whiska, "Starts the owl at login, restarts it on a crash")
  Rel(whiska, nc, "Raises a hoot herdr will not show")

  UpdateLayoutConfig($c4ShapeInRow="3", $c4BoundaryInRow="1")
```

## The three actors worth naming

- **The person** never talks to Whiska's storage directly. They type into a main session
  and answer one question at a time.
- **herdr is unchanged by this project** (ADR-0020). A mouse is not a new runtime thing —
  it is a name for a herdr pane running Claude Code. This is also the one boundary where
  mocking is allowed in tests (ADR-0031).
- **git is asked, and now also answered to.** Whether a branch has landed is a local git
  question, and it is the one that lets the owl take a merged worktree down by itself
  (ADR-0061). No forge, no network, no credentials are involved in it.
- **launchd** matters because there is exactly one owl per machine, not one process per
  repo (ADR-0001). `whiska owl install` writes the user LaunchAgent `com.whiska.owl`,
  which starts the owl at login and restarts it if it crashes (ADR-0040). The foreground
  `whiska owl` still exists, and refuses while launchd's owl is running.
