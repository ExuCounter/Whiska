# Dynamic — one `PreToolUse` decision (built)

A mouse in a worktree tries to edit something; Whiska decides and either says nothing
(allow) or prints a deny. The one rule here is the hold (ADR-0079); what a mouse's mode
forbids and the person's commands are the deny list Claude Code enforces whatever the
hook says (ADR-0090). The owl decides it in about 16 ms when it answers its hook
socket, and the escript in about 245 ms when it does not (ADR-0033). Both run the same
modules, so the steps below are the same either way.

> Mermaid numbers a `C4Dynamic` diagram's relationships itself, in declaration
> order — so the order of the `Rel` lines below is the flow, and the step numbers
> in the prose match what renders.

```mermaid
C4Dynamic
  title Dynamic Diagram - PreToolUse decision

  Container_Ext(mouse, "Mouse", "Claude Code in a herdr pane", "About to call Write or Bash")
  Container_Ext(shim, "whiska.sh", "bash", "Committed hook shim")

  Container_Boundary(cli, "The owl, or the escript when the owl does not answer") {
    Component(hook, "Hook.PreToolUse", "decision", "Orchestrates one decision")
    Component(session, "Session", "identity", "Which session is this: started where, which pane")
    Component(layout, "Layout", "path arithmetic", "Worktree root, main checkout")
    Component(markerm, "Marker", "identity", "mouse_id")
    Component(storage, "Storage", "Ecto", "House, best-effort")
    Component(rules, "Rule.Held", "rule", "Deny a held mouse, allow the rest")
  }

  Rel(mouse, shim, "Fires the hook", "JSON on stdin")
  Rel(shim, hook, "Asks the owl over hook.sock with nc; else resolves the escript and execs")
  Rel(hook, session, "Whose session is this?")
  Rel(session, layout, "Resolve the start directory to a worktree")
  Rel(hook, storage, "Read the recorded main pane; upsert the mouse, read its hold")
  Rel(hook, markerm, "Read or mint mouse_id")
  Rel(hook, rules, "Decide on the hold")
  Rel(hook, mouse, "Silence, or a deny as JSON on stdout")

  UpdateRelStyle(hook, mouse, $textColor="red", $lineColor="red", $offsetY="-20")
  UpdateLayoutConfig($c4ShapeInRow="3", $c4BoundaryInRow="1")
```

## Reading the steps

**Step 2 is where the shim earns its keep.** It reads the payload and sends it to
`~/.whiska/hook.sock` with `nc -U`, with the hook's name and the few environment variables
the hooks read — `HERDR_ENV`, `HERDR_PANE_ID`, `CLAUDE_PROJECT_DIR`, `CLAUDE_PID`, `HOME`,
`PWD` — and
the owl runs the steps below in its own process. Anything short of an answer within two
seconds sends the shim on to the escript with the payload it already read. Finding that
escript is the other half of its job: a hook does not inherit an interactive shell's
`PATH`, and a `mix escript.build` binary starts with `#!/usr/bin/env escript`, so with a
version manager the runtime is simply not found. The shim looks on `PATH`, asks `asdf`,
then reads the install directory directly. `WHISKA_BIN`, `WHISKA_ESCRIPT` and
`WHISKA_HOOK_SOCKET` override each.

**Steps 3 and 4 read an identity, not a position.** The directory Claude Code passes the
hook follows every `cd` the session runs, so the worktree comes from the directory the
session *started* in, read from the first entry of its own transcript (ADR-0053). Step 4
can fail, and that is usually an allow: a start directory outside `worktrees/<branch>/` —
the main checkout itself included — returns `{:error, :not_a_mouse}` and the call goes
through.

A start directory *under* the `worktrees/` container that is no checkout of its own —
the ordinary folder a slashed branch nests under — is nobody: no mouse, no mode, no
marker minted, and the call is allowed (ADR-0030).

**Step 5 settles whose pane this is, then reads whether the mouse is held.** A tool call firing in the pane
`whiska start` recorded is the person's own session: no mouse, no rules, nothing recorded,
and the call is allowed. The pane is the hook's own `HERDR_PANE_ID`, the one the shim
sent, never the owl's: an owl started by hand in the main session's pane would otherwise
take every mouse for the main session. Inside the owl the house is opened on a
connection of the hook's own, so hooks for two repos at once never collide. Both answers come out of the one house opening, so nothing opens
twice. If the house cannot be read, the mouse is taken as not held and Whiska says so on
stderr.

**Step 8 always exits 0.** The decision travels in the JSON body. A non-zero exit would
read to Claude Code as the hook itself having failed, which is a different and worse
signal than "denied".

## Where the time goes

| What runs | Per invocation |
|---|---|
| The shim, the owl answering (ADR-0033) | ~16 ms |
| The shim, no owl: the escript | ~245 ms |
| `whiska --version` — escript boot floor | 126 ms |
| First run ever, which also unpacks the bundled SQLite library | 627 ms, once |

Of the 16 ms, bash starting is about 2, `nc` itself about 7, and the owl's own work about
3 — most of that opening the house's database for the request. Nothing inside the escript
can remove its first 126 ms, which is why the owl answers when it can. That is why the installed matcher is
`Write|Edit|MultiEdit|NotebookEdit|Bash` and not `*`: `Read`, `Grep` and `Glob` are a
large share of all tool calls, a hold lets them pass, and they never pay the cost.
