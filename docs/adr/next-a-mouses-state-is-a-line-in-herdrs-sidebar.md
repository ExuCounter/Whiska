# A mouse's state is a line in herdr's sidebar, and the Claude Code statusline goes

**Supersedes [ADR-0051](0051-the-repo-scoped-statusline-is-a-board-the-owl-writes.md)**
— the board in this repo's Claude Code statusline — **and
[ADR-0059](0059-the-statusline-script-carries-a-version-stamp.md)**, whose script no longer
exists. **Amends [ADR-0058](0058-a-held-queue-says-so-on-the-board.md)** and
**[ADR-0065](0065-the-board-says-when-this-pane-is-not-the-main-session.md)** (what they put
on the board moves, or goes), and **[ADR-0044](0044-the-statusline-redraws-on-a-timer-not-a-typed-nudge.md)**
and **[ADR-0048](0048-the-owls-line-is-drawn-on-herdrs-tab-bar.md)** (there is no
repo-scoped Claude Code line left to redraw; the tab bar is unchanged).

The board answered "what is every mouse doing" in the main session's statusline: rows of
branch, status, elapsed and detail, redrawn every second. It sat away from the mice it
described — the person reads it in one place and clicks a mouse's workspace in another —
and it cost a script run every second in every open session.

herdr 0.9 draws custom lines under each workspace in its left sidebar, from tokens a
program reports on that workspace (`workspace.report_metadata`), coloured by rules in the
person's own config. The line goes where the person clicks to reach the mouse. Decided
with the person on 2026-10-07 after a live demo on herdr 0.9.3.

## Decision

**The owl writes each mouse's state under that mouse's own workspace**, in three tokens:
`whiska`, the state; `whiska_q` and `whiska_q2`, the question it carries, word-wrapped at
31 characters, at most two lines, the second cut with `…`. A mouse with nothing to report —
idle, nothing waiting — has no line at all. `Whiska.Sidebar` turns the board's facts
(`Whiska.Watch.board/2`, which now holds facts and no words) into the tokens; the house
sends them.

**The states, in the order they sort, first match winning:**

| # | line | carries |
|---|------|---------|
| 1 | `🐭 #13 · waiting on you · 14m` — sent, unanswered | the question |
| 2 | `🐭 #12 · waiting on you` — next to go; `🐭 #12 · answer not taken` | the question |
| 3 | `✅ #14 · finished` — a report holding the slot | its closing line |
| 4 | `⚠ stuck 6m` — blocked, or working and silent two minutes | its last action |
| 5 | `⏳ queued behind #12` | the question |
| 6 | `✅ finished · queued behind #12` | |
| 7 | `🎯 #16 · waits: focus on <branch>` | |
| 8 | `💤 #15 · waits: away` | |
| 9 | `⏸ #17 · held`, `⏸ held` | |
| 10 | `↩ picked up 2m ago` | |
| 11 | `◐ <topic, else last action>` | |
| 12 | `✖ no pane`, `⚠ many panes`, `? herdr can't say` | |

A hold is checked first, then the question, then herdr's view of the pane, then stuck,
picked up and working. Ages are minutes — `<1m`, `14m`, then `Whiska.Mice.format_uptime/1`
from an hour — because a line is re-sent whenever its words change, and one that ticked in
seconds would be sent every second. The person picked 🐭 for the lines that wait on them:
the line is the mouse's.

**A working mouse's line is animated**: its symbol turns ◐ ◓ ◑ ◒, one step per write, the
board's ticker carried over. A still spinner on a working mouse means the owl has stopped,
and thirty seconds later the line expires.

**Every line starts with a symbol only Whiska writes, and that symbol is the colour key.**
herdr colours a token by rules on its own text — `equals`, `contains`, `starts_with` — and
cannot look at a second token, so a hidden state token cannot colour the line. The demo's
`contains = "waiting"` rules made a working mouse whose topic mentioned waiting turn orange.
Matching `starts_with` on the first symbol cannot be tripped that way: free text — a topic,
a branch — only ever comes after it. Colour lives in the person's config, never in Whiska
(ADR-0048); `whiska doctor` prints the rows (`Whiska.Sidebar.snippet/0`, fourteen rules,
within herdr's sixteen) and checks herdr is 0.9 or newer, the version `rules` and
`report_metadata` arrived in.

**The main checkout's workspace carries the repo's own line**, in the same three tokens,
most urgent first: `✖ no main session: whiska start` (only while something runs or
waits), `⏳ gated: <reason>` (ADR-0058's reasons in sidebar width — `you're typing`,
`no prompt box`, `main is mid-turn`, `main unreachable` — after its ten-second fuse, and
not while the person is away), `🐭 n more: whiska questions` (questions no mouse's line
can show: a mouse with no workspace, or a record that is gone), and `◌ n orphaned
(branches)` (the board's orphan line, uncoloured). The fourth is dropped when all four are
true. Each fits the sidebar's width with the command it names at its end.

**herdr forgets every token when its server restarts, so the owl reads them back.** Every
time the house asks herdr for its panes (every two seconds) it also asks for its workspaces,
which carry the tokens herdr holds, and sends each line whose tokens differ. A restart is
the tokens being gone. In between, a line is sent when it differs from what was last sent.
Every line is sent with a **TTL of thirty seconds** and sent again twenty seconds after its
last send, so a dead owl's lines expire rather than lie. Every send names all three tokens,
an absent one as `null`, so a line that got shorter clears what it no longer says, and a
mouse that stops having anything to say is cleared rather than left to expire.

**A house speaks only for its own workspaces**: those it has a line for, those it has sent
to before, and any open on a worktree under its main checkout. Another repo's lines are
never touched.

**The mice re-sort with `workspace.move_block` only when the set of them needing the person
changes** — states 1 to 3 — and once when the house opens. Mice of the same state keep the
order they are in, so the person's own drag order stands everywhere else, and rows never
move under the cursor for any other reason. The block lands where its first member sits:
anchored before the first workspace after it that is not one of the mice, or at the end.
The main checkout's workspace never moves. `move_block` is in herdr's socket API but not its
CLI or docs; if herdr renames it, sorting fails with one warning and the lines still work.

**A mouse's workspace** is the one open on its worktree, else one opened on no checkout
that holds its agent pane — never one open on another checkout, and never the main
checkout's. A workspace two mice would share goes to the one that wants the person more;
a mouse left without one is counted on the main checkout's line.

**The Claude Code statusline goes.** `whiska init` writes no `statusLine` and no script,
and takes out what an older init wrote: the repo's committed script, its settings entry,
and — globally — puts the line the global install displaced (ADR-0056) back into
`~/.claude/settings.json` before deleting the file it was kept in. A `statusLine` that is not
Whiska's is never touched, and a file reached through a symlink is named, not deleted. Until
a repo re-runs `init`, its old script finds no board — the owl deletes its board files when a
house opens — and prints only the person's own line; `whiska statusline --here`, which older
scripts call, prints nothing. `whiska doctor` names any leftover as a warning with the init
that removes it.

**`whiska watch` prints what the owl writes to the sidebar**, worked out on the spot: the
main checkout's lines, then each mouse in sidebar order under its branch, from the same
`Whiska.Sidebar`. It is the check for "why does the sidebar look like that".

## Consequences

- **Not every surface of ADR-0065 survives.** "No main session here" moves to the main
  checkout's line. "Answers go to another pane" cannot be said in a sidebar, which looks the
  same from every pane; `whiska doctor` still says `(not this pane)` beside the recorded one.
- **The five-row cap, the elapsed column and ANSI colour are gone.** The sidebar has a line
  per workspace already, and the person's herdr theme does the colour.
- **A sort renumbers workspaces**, so anything that jumps by workspace number lands somewhere
  else afterwards. Whiska addresses workspaces by id.
- **Cost:** one `workspace.list` per house every two seconds beside the `pane.list` it
  already asks, and one `report_metadata` per changed line — every second for a working
  mouse, because of the spinner. Nothing runs in any Claude Code session any more.
- **herdr 0.8 draws nothing**: the call is refused, the house warns once, and collection
  and delivery carry on. The first refused or unanswered send ends that tick's sending, so
  a herdr that is down or hung costs one try a second, and a herdr that comes back gets
  every line again on the next tick.

## Considered options

**A separate state token matched with `equals`.** Robust, but herdr colours a token only
by its own text, so the state word would have to be visible — `waiting · #13 · 14m` — which
changes the approved wording and puts herdr's separator mid-line.

**Keep the demo's `contains` rules.** Free text in a working mouse's line can match them.

**Drop the repo-wide lines with the statusline.** A paused queue would be silent again —
the afternoon ADR-0058 was written to end.

**Keep `whiska watch` printing the old board.** A second view of the same facts, which can
disagree with the sidebar it is meant to explain.

**Re-sort on every change.** Rows would jump under the cursor and undo the person's drag
order every two seconds.
