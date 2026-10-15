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

One row: the context size, then the state, then a working mouse's topic, each a token of
its own, which herdr joins with ` · ` and leaves out when absent. herdr's own icon beside
the workspace already says working and idle, so those two states have no words of their
own: a working mouse's row is `163K · <topic>`, an idle one's `212K`. Nothing is carried
under the row: no question, report or last action is excerpted, since the sidebar cut each
at its width, some went stale, and the main session holds them whole. The states, in the
order they sort (which one a mouse is in is decided as the paragraph under the list says):

1. `❓ waiting on you · 14m` — sent, unanswered.
2. `❓ waiting on you` — next to go; `❓ answer not taken`.
3. `✖ stuck 6m` — blocked, or working with no subagent out and silent two minutes in a tool or five waiting on the model, or idle with its last stop passed over and that work unreported past ADR-0052's half hour.
4. `⏳ queued`.
5. `↩ picked up 2m ago`.
6. Working: the topic, else the last action, else `working`, in `whiska_topic`. An idle pane whose last stop was passed over while its own background work runs is working too, and says `◐ background` before its topic, since herdr's icon calls it idle.
7. `✖ no pane`, `⚠ many panes`, `? herdr can't say`.
8. Idle: nothing but the size.
9. `🎯 waits: focus on <branch>`.
10. `💤 waits: away`.
11. `⏸ held`.
12. `✅ finished` — its report is still its last word, and its branch has neither landed nor a merge request.

**The order follows the work, not the kind of mouse.** The mice the person set aside (9 to
11) sit below idle ones, and a finished mouse, which waits on nobody, sits last. Of mice in the same state a build mouse comes before a sniff mouse,
so a sniff mouse waiting on the person still sits among those that need them. A mouse queued
behind a question (4) sits right under the mouse that holds that question, queued
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
is read from the mouse's own transcript, never asked for (ADR-0050). It is shown only for
a working mouse with no topic, and its age is what tells stuck from working: a pane herdr
calls blocked, or one working that has written nothing for longer than what it waits on
explains, is stuck. A subagent keeps its own file, and
herdr keeps the pane working while one is out, so a mouse waiting on one is working and
never stuck, up to ADR-0052's half-hour bound. Other background work leaves herdr calling
the pane idle (checked in a throwaway pane on 2026-10-14), so an idle mouse with nothing to
say whose last stop was passed over (ADR-0052) reads as working while that work runs, and
stuck once it is past the half hour unreported; its transcript is read once per change to
the file, never per rebuild. Once a
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

**The merge request the mouse's branch waits on is one more row** (ADR-0087), what the
owl last read of it (ADR-0060), as three tokens joined by ` · `:

- `whiska_mr`: the request named the way its forge names it, `⎇ !123` or `⎇ #12`.
- `whiska_ci`: its head pipeline, `✓`, `◐` or `✗`.
- `whiska_review`: `2 threads open`, `ready to merge`, or, once it is no longer open,
  `merged`, `closed`, `deleted`; `unread 20m` when reads have failed three minutes or
  more, in place of all of it.

A part with nothing to say is left out, so before the first read, and for a forge the owl
does not read, the row is `⎇ !123` alone. herdr cuts a row at the sidebar's width.

**The line carries the mouse's context size first**, `142K`: the input, cache-read and
cache-creation tokens of the last assistant message in its transcript, read the same way
as the last action (ADR-0050), for every mouse with a line, since a mouse waiting on the
person is the one whose length matters. That makes one 64 KB tail read per live mouse
per tick, plus the `Stop` hook's tail (ADR-0052) for a working mouse quiet two minutes, where the last action was read only for a working or blocked one; it is read
from the tail alone, so one very large message can leave a mouse without a size for a
moment. It comes first on every state (`236K · ✅ finished`, `447K · ⏸ held`), so it reads
as a column. It goes in one of three tokens by how near the mouse's auto-compact window it
is: `whiska_ctx` under two thirds, `whiska_ctx_warn` from there, `whiska_ctx_full` from nine
tenths. The window is the one `priv/models.json` gives the mouse's model, 300K by default
and 100K on haiku; a sniff mouse runs without one and is measured against it all the same.
A line that says the pane is lost (`✖ no pane`, `⚠ many panes`, `? herdr can't say`) has
no size. No line carries a question's id: it is not what the person acts on, and `whiska
questions` has it. `whiska mice` shows the size in its own column.

**A colour is chosen by which token a value is in, or by a rule on text only Whiska
writes.** herdr colours a token by rules on its own text (`equals`, `contains`,
`starts_with`, and numeric `gt`/`lt` on a value that is a bare number) and cannot read a
second token. `contains = "waiting"` turned a working mouse orange when its topic mentioned
waiting. So the state token is only ever Whiska's words and starts with a symbol nothing
else does, keyed by `starts_with`; the topic, free text, has a token of its own with one
colour; the size's band is its token, since `212K` is no number to herdr and a fixed
threshold could not follow a haiku mouse's smaller window; and the pipeline and review
tokens are keyed on their own words. Colour lives in the person's config, never in Whiska
(ADR-0048); `whiska doctor` prints the rows (`Whiska.Sidebar.snippet/0`), warns when a
token Whiska reports is drawn by none of them, and checks herdr is 0.9 or newer. A stopped
owl shows when its lines expire, thirty seconds after the last send.

**Nothing on the sidebar is a link.** herdr strips control characters from a token's text,
so an OSC 8 link cannot reach it, and its tab bar strips escape sequences the same way.
`whiska merge-request open` opens the merge request of the mouse whose worktree holds the
directory it runs in, for a key in the person's herdr config, which runs it in the focused
pane's directory (ADR-0085).

## The main checkout's line

Three tokens, `whiska`, `whiska_q` and `whiska_q2`, most urgent first:

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
rather than lie. Every send names every token, an absent one as `null`, so a line that
got shorter clears what it no longer says.

**A house speaks only for its own workspaces** and never touches another repo's lines.

**The mice re-sort with `workspace.move_block` only when a mouse changes state (its
place in the list; the three lost-pane lines are one), or starts or stops queueing behind another (states 4 and 5)**, and
once when the house opens. A held mouse used
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
  `report_metadata` per changed line.
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
- **A spinner on a working mouse's line, and `○ idle`.** Both repeated herdr's own icon
  beside the workspace; the spinner's one use, a still one meaning the owl had stopped,
  is covered by the lines expiring.
- **The question, report summary or last action under the line.** Cut at the sidebar's
  width, sometimes stale, and the main session has them whole.
- **The merge request as one grey row.** It ran past the sidebar's width, and one colour
  could not tell a failed pipeline from a ready request.
- **The size coloured by herdr's numeric rules.** `142K` is no number to herdr, and a
  fixed threshold cannot follow each model's window.
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

Changed on 2026-10-14: an idle mouse whose last stop was passed over while its own background work runs reads as working, and as stuck once that work is half an hour old unreported (ADR-0052).

Changed on 2026-10-15: working and idle lines have no words of their own, since herdr's icon says them, but for `◐ background`, which it cannot; no line carries an excerpt; the size comes first, coloured by its band against the mouse's auto-compact window; the merge request is two rows coloured by part; a finished mouse sorts last; `whiska merge-request open` stands in for a link herdr cannot draw.

Changed on 2026-10-15 (polish): the merge request is one row, not two: its name, pipeline and review joined by ` · `.
