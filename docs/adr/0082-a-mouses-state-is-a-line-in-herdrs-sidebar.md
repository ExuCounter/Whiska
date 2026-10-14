# A mouse's state is a line in herdr's sidebar

The owl writes each mouse's state under that mouse's own workspace in herdr's sidebar,
and the main checkout's workspace carries what is true of the whole repo. Whiska draws
nothing in Claude Code's statusline: `whiska init` writes no `statusLine` and no script,
and takes out what an older init wrote.

The line goes where the person clicks to reach the mouse. herdr 0.9 draws custom lines
under each workspace from tokens a program reports on it (`workspace.report_metadata`),
coloured by rules in the person's own config. Decided with the person after a live demo
on herdr 0.9.3.

## A mouse's line

Three tokens: `whiska`, the state; `whiska_q` and `whiska_q2`, the question it carries,
word-wrapped at 31 characters, at most two lines, the second cut with `…`. The states, in the order they
sort (which one a mouse is in is decided as the paragraph under the table says):

| # | line | carries |
|---|------|---------|
| 1 | `❓ waiting on you · 14m` — sent, unanswered | the question |
| 2 | `❓ waiting on you` — next to go; `❓ answer not taken` | the question |
| 3 | `✅ finished` — its report is still its last word, and its branch has neither landed nor a merge request | the first line of its `## Summary` |
| 4 | `✖ stuck 6m` — blocked, or working with no subagent out and silent two minutes in a tool or five waiting on the model | its last action |
| 5 | `⏳ queued` | the question |
| 6 | `↩ picked up 2m ago` | |
| 7 | `◐ <topic, else last action>` | |
| 8 | `✖ no pane`, `⚠ many panes`, `? herdr can't say` | |
| 9 | `○ idle` | |
| 10 | `🎯 waits: focus on <branch>` | |
| 11 | `💤 waits: away` | |
| 12 | `⏸ held` | |

**The order follows the work, not the kind of mouse.** The mice the person set aside (10 to
12) sit below idle ones. Of mice in the same state a build mouse comes before a sniff mouse,
so a sniff mouse waiting on the person still sits among those that need them. A mouse queued
behind a question (5) sits right under the mouse that holds that question, queued
mice in question order, whatever the mode of either; one whose holder is not on the board
keeps its own state's place.

A hold is checked first, then the question, then herdr's view of the pane, then stuck,
picked up and working. Ages are minutes, then `Whiska.Mice.format_uptime/1` from an hour:
a line is re-sent whenever its words change, and one ticking in seconds would be sent every
second. The person picked ❓ for the lines that wait on them: a question for the person (the plain `?` is taken by `? herdr can't say`).

**The facts behind the line** are the board, `Whiska.Watch.board/2`, which holds facts and
no words: the question waiting, how the pane stands with herdr, the mouse's topic and its
last action. The topic is herdr's `terminal_title_stripped`, the short summary Claude Code
keeps of what a session is on, already in the pane list the house asks for. The last action
is read from the mouse's own transcript, never asked for (ADR-0050), and shown only where
the topic would mislead: a pane herdr calls blocked, or one working that has written
nothing for longer than what it waits on explains. A subagent keeps its own file, so a
mouse waiting on one is working and never stuck, up to ADR-0052's half-hour bound; once a
working mouse has been quiet two minutes, and for no other, the transcript is read as far
back as the `Stop` hook reads it (ADR-0052), since a launch can sit further back than the
every-tick read reaches. In a tool, Claude Code writes the result as soon as there is one, so two
minutes is a long call or a stall (shorter would flip on an ordinary test run). Waiting on
the model, it writes nothing until the answer arrives, and a long think over a large context
ran past three minutes on 2026-10-11, so that wait reads as working until five; longer
would hide a hung model call for good. Which line is a question is read from the question's
id, never from the words: a topic beginning `waiting on you · #99` must not forge one.
A dead mouse (ADR-0026) has no line; what it left is counted on the main checkout's. Every
free string, a topic or a branch, is stripped to one line with no control characters before
it reaches herdr.

**A fourth token, `whiska_mr`, is the merge request the mouse's branch waits on**
(ADR-0087), its own row under the question, so neither the state nor the question gives
way to it. It is named the way its forge names it, `⎇ !123` or `⎇ #12`, and after it what
the owl last read (ADR-0060), the first of these that holds:

| read | row |
|------|-----|
| merged, closed, or gone from the forge | `⎇ !123 · merged`, `· closed`, `· deleted` |
| reads failing for three minutes or more | `⎇ !123 · unread 20m` |
| head pipeline failed | `⎇ !123 · pipeline ✗ · 2 threads` |
| ready to merge | `⎇ !123 · ready to merge` |
| threads open | `⎇ !123 · 2 threads open · ✓` (`◐` while the pipeline runs) |
| pipeline running, passed, or none | `⎇ !123 · pipeline ◐`, `· ✓`, `· open` |

What does not fit 31 characters drops from its end, down to the name alone, which is
also the row before the first read and for a forge the owl does not read. The row has no
colour rule: its symbol is the same on every row, so there is nothing to key on.

**The line carries the mouse's context gauge, straight after the symbol**, `◐ 142K · <topic>`: the input, cache-read and
cache-creation tokens of the last assistant message in its transcript, read the same way
as the last action (ADR-0050), for every mouse with a line, since a mouse waiting on the
person is the one whose length matters. That makes one 64 KB tail read per live mouse
per tick, plus the `Stop` hook's 512 KB tail for a working mouse quiet two minutes, where the last action was read only for a working or blocked one; it is read
from the tail alone, so one very large message can leave a mouse without a gauge for a
moment. It sits in the same place on every state (`✅ 236K · finished`, `⏸ 447K · held`), so it
reads as a column and a long topic cannot cut it off. No line carries a question's id: it
is not what the person acts on, and `whiska questions` has it. A finished mouse's second
line is the first line of its report's `## Summary` (else the last line before `Agent usage
this session`), never the agent ledger the report ends in. A line that says the pane is lost (`✖ no pane`, `⚠ many panes`,
`? herdr can't say`) has none. With an auto-compact window the size
is followed by a five-cell bar (`142K ▰▰▰▱▱`); no mouse has a window yet. `whiska mice`
shows the same gauge in its own column.

**Only Whiska's symbol starts a line, and it is the colour key.** herdr colours a token by
rules on its own text (`equals`, `contains`, `starts_with`) and cannot read a second token.
`contains = "waiting"` turned a working mouse orange when its topic mentioned waiting;
`starts_with` on the symbol cannot be tripped, because free text only ever follows it.
Colour lives in the person's config, never in Whiska (ADR-0048); `whiska doctor` prints the
rows (`Whiska.Sidebar.snippet/0`, fifteen rules within herdr's sixteen) and checks herdr
is 0.9 or newer. A working mouse's symbol turns ◐ ◓ ◑ ◒, one step per write: a still
spinner means the owl has stopped, and thirty seconds later the line expires.

## The main checkout's line

The same three tokens, most urgent first:

- `✖ no main session: whiska start`, only while something runs or waits. Only the wrong
  case is said: a permanent "you are the whiska" badge would be furniture nobody reads,
  and the day it was absent nobody would notice. The sidebar looks the same from every
  pane, so "not the main session" cannot be said here; `whiska doctor` says `(this pane)`
  or `(not this pane)` beside the recorded one, compared with `HERDR_PANE_ID`.
- `⏳ gated: <reason>` (`you're typing`, `no prompt box`, `main is mid-turn`,
  `main unreachable`) once a hold has lasted ten seconds, and not while the person is
  away. The holds are right and silent (ADR-0008, ADR-0047), and a silent hold was an
  afternoon of not knowing a queue existed. Ten seconds is the person's own fuse: a reason
  that flickers during a pause is cheaper than a queue nobody knows about. One hold however
  its reason changes, so alternating reasons cannot reset the fuse. A reason Whiska cannot
  name is still a hold, said as the main session being unreachable; `whiska doctor` keeps
  the long words. The line is as current as the last delivery attempt: a draft deleted
  and walked away from reads as a draft until the next trigger, at worst one backstop.
- `❓ n more: whiska questions`, questions no mouse's line can show.
- `◌ n orphaned (branches)`, named by branch, since the branch survives on the record
  (ADR-0007) and is what `whiska questions` prints; `#id` when there is none.
- `⎇ n merge requests, no worktree`, requests the owl still reads for a branch that was
  dropped while they were open (ADR-0087): no mouse line is left to show them.

## Keeping the lines true

**herdr forgets every token when its server restarts, so the owl reads them back.** With
every pane list (every two seconds) the house also lists its workspaces, which carry the
tokens herdr holds, and sends each line whose tokens differ. Every line has a TTL of thirty
seconds and is sent again twenty seconds after its last send, so a dead owl's lines expire
rather than lie. Every send names all four tokens, an absent one as `null`, so a line that
got shorter clears what it no longer says.

**A house speaks only for its own workspaces** and never touches another repo's lines.

**The mice re-sort with `workspace.move_block` only when a mouse changes state (its
row in the table; the three lost-pane lines are one row), or starts or stops queueing behind another (states 5 and 6)**, and
once when the house opens. The spinner turning is not a change of state. A held mouse used
to stay where it was until a question moved the rows, which left it between working ones;
now it drops at once. A new mouse that is not idle re-sorts at once, since one first seen
already working would otherwise sit under held mice until another mouse changed state; a new
idle mouse, or one that goes, does not: it lands in place at the next re-sort. Mice of one state and mode keep their order, so the
person's drag order stands. The main checkout's workspace never moves. `move_block` is
in herdr's socket API and not its docs; a rename fails sorting with one warning.

**A mouse's workspace** is the one open on its worktree, else one opened on no checkout
that holds its agent pane; never another checkout's, never the main checkout's. A
workspace two mice would share goes to the one that wants the person more.

**The statusline goes.** `whiska init` removes the repo's committed script and its settings
entry, and globally restores the line the global install displaced (ADR-0056). A
`statusLine` that is not Whiska's is never touched; a file behind a symlink is named, not
deleted. `whiska doctor` names any leftover as a warning with the init that removes it.

**`whiska watch` prints what the owl writes**, worked out on the spot from the same
`Whiska.Sidebar`: the check for "why does the sidebar look like that".

## Consequences

- Nothing runs in any Claude Code session for Whiska any more.
- Cost: one `workspace.list` per house every two seconds beside the `pane.list`, and one
  `report_metadata` per changed line, every second for a working mouse.
- herdr 0.8 draws nothing: the call is refused, the house warns once, collection and
  delivery carry on. The first refused send ends that tick's sending.
- A sort renumbers workspaces; Whiska addresses them by id.
- The doorstep is not on any line: with the owl down the lines expire, and the tab bar
  says `🦉 owl down` (ADR-0048).

## Considered options

- **A board in Claude Code's statusline**, rows the owl wrote to a file and a script
  printed every second. It sat away from the mice it described and cost a script run per
  second in every open session, running the person's global statusline each time.
- **A separate state token matched with `equals`.** The state word would have to be
  visible, changing the approved wording.
- **Keep the demo's `contains` rules.** Free text can match them.
- **Drop the repo-wide lines with the statusline.** A gated queue would be silent again.
- **A desktop notification for a gated queue.** The gate exists not to interrupt.
- **Deliver anyway after a timeout.** Typing into somebody's draft is what the gate
  prevents.
- **Re-sort on every tick.** Rows would jump under the cursor every two seconds.
- **Re-sort only when a question moves** (the first version of this ADR). A mouse that
  was held, went idle or lost its pane stayed among the wrong rows until one did.
- **Say "not the main session" at session start.** Read once, when least relevant, and
  scrolled away by the time the person is waiting.

Changed on 2026-10-11: an idle mouse says `○ idle`, and the mice re-sort on any change of state, and when a new mouse appears in any state but idle.
Changed on 2026-10-12: a working mouse is stuck after two minutes' silence in a tool or five waiting on the model, where it was two minutes whatever it waited on; and a subagent started further back than the short tail still counts as out.

Changed on 2026-10-14: no mouse line carries a question's id; the context gauge follows the symbol on every state; a finished mouse carries its report's summary line, not its last line.

Changed on 2026-10-14: a fourth token, `whiska_mr`, is a mouse's merge request row, and the main checkout's line counts open requests with no worktree.

Folded in on 2026-10-08: 0051, 0058, 0059, 0065 (their text is in git history).

Changed on 2026-10-14: `✅ finished` means finished and not landed: it stays until the branch lands, gets a merge request or is dropped, or its mouse asks or works again, and it waits on nobody, so the main checkout's line never counts it. `✅ finished · queued` is gone, since a finished report never queues (ADR-0008).
