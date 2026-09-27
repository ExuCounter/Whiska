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
  System_Ext(launchd, "launchd", "Will supervise the one owl per machine - not wired yet")

  Rel(person, claude, "Types into the main session")
  Rel(claude, whiska, "Sends hook events", "JSON on stdin / socket")
  Rel(whiska, claude, "Denies a tool call, or types an answer into a mouse")
  Rel(whiska, herdr, "Opens panes, reads agent status", "herdr CLI")
  Rel(herdr, claude, "Starts and hosts every session")
  Rel(whiska, git, "Derives layout from, stores house under .git/")
  Rel(launchd, whiska, "Keeps the owl awake")

  UpdateLayoutConfig($c4ShapeInRow="3", $c4BoundaryInRow="1")
```

## The three actors worth naming

- **The person** never talks to Whiska's storage directly. They type into a main session
  and answer one question at a time.
- **herdr is unchanged by this project** (ADR-0020). A mouse is not a new runtime thing —
  it is a name for a herdr pane running Claude Code. This is also the one boundary where
  mocking is allowed in tests (ADR-0031).
- **launchd** matters because there is exactly one owl per machine, not one process per
  repo (ADR-0001). The owl exists today but runs in the foreground; the supervision is
  designed, not wired.
