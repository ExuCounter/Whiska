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
word-wrapped at 31 characters, at most two lines, the second cut with `…`. A mouse with
nothing to report, idle with nothing waiting, has no line. The states, in the order they
sort, first match winning:

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
picked up and working. Ages are minutes, then `Whiska.Mice.format_uptime/1` from an hour:
a line is re-sent whenever its words change, and one ticking in seconds would be sent every
second. The person picked 🐭 for the lines that wait on them: the line is the mouse's.

**The facts behind the line** are the board, `Whiska.Watch.board/2`, which holds facts and
no words: the question waiting, how the pane stands with herdr, the mouse's topic and its
last action. The topic is herdr's `terminal_title_stripped`, the short summary Claude Code
keeps of what a session is on, already in the pane list the house asks for. The last action
is read from the mouse's own transcript, never asked for (ADR-0050), and shown only where
the topic would mislead: a pane herdr calls blocked, or one working that has written
nothing for two minutes (Claude Code appends every few seconds while a turn runs; shorter
would flip on an ordinary test run). Which line is a question is read from the question's
id, never from the words: a topic beginning `waiting on you · #99` must not forge one.
A dead mouse (ADR-0026) has no line; what it left is counted on the main checkout's. Every
free string, a topic or a branch, is stripped to one line with no control characters before
it reaches herdr.

**Only Whiska's symbol starts a line, and it is the colour key.** herdr colours a token by
rules on its own text (`equals`, `contains`, `starts_with`) and cannot read a second token.
`contains = "waiting"` turned a working mouse orange when its topic mentioned waiting;
`starts_with` on the symbol cannot be tripped, because free text only ever follows it.
Colour lives in the person's config, never in Whiska (ADR-0048); `whiska doctor` prints the
rows (`Whiska.Sidebar.snippet/0`, fourteen rules within herdr's sixteen) and checks herdr
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
- `🐭 n more: whiska questions`, questions no mouse's line can show.
- `◌ n orphaned (branches)`, named by branch, since the branch survives on the record
  (ADR-0007) and is what `whiska questions` prints; `#id` when there is none.

## Keeping the lines true

**herdr forgets every token when its server restarts, so the owl reads them back.** With
every pane list (every two seconds) the house also lists its workspaces, which carry the
tokens herdr holds, and sends each line whose tokens differ. Every line has a TTL of thirty
seconds and is sent again twenty seconds after its last send, so a dead owl's lines expire
rather than lie. Every send names all three tokens, an absent one as `null`, so a line that
got shorter clears what it no longer says.

**A house speaks only for its own workspaces** and never touches another repo's lines.

**The mice re-sort with `workspace.move_block` only when the set needing the person (states
1 to 3) changes**, and once when the house opens. Mice of one state keep their order, so
the person's drag order stands. The main checkout's workspace never moves. `move_block` is
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
- **Re-sort on every change.** Rows would jump under the cursor every two seconds.
- **Say "not the main session" at session start.** Read once, when least relevant, and
  scrolled away by the time the person is waiting.

Folded in on 2026-10-08: 0051, 0058, 0059, 0065 (their text is in git history).
