# Dynamic — one `PreToolUse` decision (built)

The only flow that runs end to end today. A mouse in a worktree tries to edit something;
Whiska decides in ~220 ms and either says nothing (allow) or prints a deny.

> Mermaid numbers a `C4Dynamic` diagram's relationships itself, in declaration
> order — so the order of the `Rel` lines below is the flow, and the step numbers
> in the prose match what renders.

```mermaid
C4Dynamic
  title Dynamic Diagram - PreToolUse decision

  Container_Ext(mouse, "Mouse", "Claude Code in a herdr pane", "About to call Write or Bash")
  Container_Ext(shim, "whiska.sh", "bash", "Committed hook shim")

  Container_Boundary(cli, "whiska escript") {
    Component(hook, "Hook.PreToolUse", "decision", "Orchestrates one decision")
    Component(session, "Session", "identity", "Which session is this: started where, which pane")
    Component(layout, "Layout", "path arithmetic", "Worktree root, main checkout")
    Component(markerm, "Marker", "identity", "mouse_id")
    Component(storage, "Storage", "Ecto", "House, best-effort")
    Component(rules, "Rule.Sniff + Rule.MainCheckout", "rules", "Allow or deny")
  }

  Rel(mouse, shim, "Fires the hook", "JSON on stdin")
  Rel(shim, hook, "Resolves escript and execs")
  Rel(hook, session, "Whose session is this?")
  Rel(session, layout, "Resolve the start directory to a worktree")
  Rel(hook, storage, "Read the recorded main pane; upsert the mouse, read its mode")
  Rel(hook, markerm, "Read or mint mouse_id")
  Rel(hook, rules, "Decide on tool name and input")
  Rel(hook, mouse, "Silence, or a deny as JSON on stdout")

  UpdateRelStyle(hook, mouse, $textColor="red", $lineColor="red", $offsetY="-20")
  UpdateLayoutConfig($c4ShapeInRow="3", $c4BoundaryInRow="1")
```

## Reading the steps

**Step 2 is where the shim earns its keep.** A hook does not inherit an interactive
shell's `PATH`, and a `mix escript.build` binary starts with `#!/usr/bin/env escript`, so
with a version manager the runtime is simply not found. The shim looks on `PATH`, asks
`asdf`, then reads the install directory directly. `WHISKA_BIN` and `WHISKA_ESCRIPT`
override both.

**Steps 3 and 4 read an identity, not a position.** The directory Claude Code passes the
hook follows every `cd` the session runs, so the worktree comes from the directory the
session *started* in, read from the first entry of its own transcript (ADR-0053). Step 4
can fail, and that is an allow: a start directory outside `worktrees/<branch>/` — the main
checkout itself included — returns `{:error, :not_a_mouse}` and the call goes through.

**Step 5 settles whose pane this is, then reads the mode.** A tool call firing in the pane
`whiska start` recorded is the person's own session: no mouse, no rules, nothing recorded,
and the call is allowed. Both answers come out of the one house opening, so nothing opens
twice. The mode half is best-effort and step 7 does not depend on it — if it cannot be
read, Whiska assumes `build` and says so on stderr, and worktree containment is pure path
arithmetic that keeps working regardless.

**Step 8 always exits 0.** The decision travels in the JSON body. A non-zero exit would
read to Claude Code as the hook itself having failed, which is a different and worse
signal than "denied".

## Where the time goes

| What runs | Per invocation |
|---|---|
| `whiska --version` — escript boot floor | 126 ms |
| `whiska hook pre-tool-use` — the real job, SQLite included | ~220 ms |
| First run ever, which also unpacks the bundled SQLite library | 627 ms, once |

The SQLite work itself — open, migrate, upsert — is under 2 ms. Nothing inside the
program can remove the first 126 ms. That is why the installed matcher is
`Write|Edit|MultiEdit|NotebookEdit|Bash` and not `*`: `Read`, `Grep` and `Glob` are a
large share of all tool calls, can never be denied, and never pay the cost.
