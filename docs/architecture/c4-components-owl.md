# Component Diagram — the owl

Level 3 for the owl, which is real code as of the owl slice. Everything here is in
`lib/whiska/owl/`, `lib/whiska/doorstep*`, `lib/whiska/herdr*`, `lib/whiska/delivery/`,
`lib/whiska/open_houses.ex`, `lib/whiska/backstop.ex`, `lib/whiska/watch*`,
`lib/whiska/cleanup.ex`, `lib/whiska/pickup.ex`, `lib/whiska/doorbell.ex`,
`lib/whiska/mouse_pane.ex`, `lib/whiska/git.ex` and
`lib/whiska/question/marker.ex`, each
with a test beside it.

```mermaid
C4Component
  title Component Diagram - the owl

  System_Ext(herdrd, "herdr", "Panes and agent status")
  System_Ext(nc, "Desktop notifications", "terminal-notifier or osascript on macOS, notify-send on Linux")
  Container_Ext(cliboot, "whiska owl", "escript command", "Boots the owl in the foreground")

  Container_Boundary(owl, "Owl") {
    Component(sup, "Whiska.Owl", "Supervisor", "One House per open project, each supervised alone")
    Component(house, "Whiska.Owl.House", "GenServer", "Pane discovery, subscription, collection, delivery")
    Component(herdrb, "Whiska.Herdr", "behaviour", "The one mocked boundary (ADR-0031)")
    Component(sock, "Whiska.Herdr.Socket", "gen_tcp on a Unix socket", "Newline-delimited JSON; list_panes, subscribe, worktree remove")
    Component(cleanup, "Whiska.Cleanup", "sweep", "One pass per backstop: note every landed branch, then take down the clean, pushed, quiet ones")
    Component(pickup, "Whiska.Pickup", "sweep", "One pass per backstop: whose turn ended without reaching the doorstep, and one line into that pane. Never a mouse with an answer not yet taken")
    Component(bell, "Whiska.Doorbell", "sweep", "One pass per backstop: every answer saved and not taken, rung again at most three times, then marked not taken")
    Component(mousepane, "Whiska.MousePane", "bounds", "Which pane is a mouse's, whether herdr calls its folder a worktree of this checkout, and what its prompt box holds")
    Component(gitq, "Whiska.Git", "git", "Merged, reached by a merge, clean, unpushed - and the removals, never forced")
    Component(doorstep, "Whiska.Doorstep", "file store", "Reads entries, marks them collected by rename")
    Component(entry, "Whiska.Doorstep.Entry", "struct", "mouse_id, branch, worktree_root, stamped_at, text, and ran_on: the model the turn ran on")
    Component(markerq, "Whiska.Question.Marker", "classifier", "done / needs-decision / unmarked, by marker alone")
    Component(draft, "Whiska.Delivery.Draft", "classifier", "Where would the line land? empty / typing / no box / unknown")
    Component(mode, "Whiska.Delivery.Mode", "judge", "What the person set aside: away (a file), this house's focus, its held mice. What goes next, oldest first, and why a question waits")
    Component(storage, "Whiska.Storage", "Ecto", "Questions, mode, dead and removed mice")
    Component(hoot, "Whiska.Delivery.Hoot", "composer", "The desktop notification for a delivered question, in the delivered line's own words; sends it through herdr, and on the desktop when herdr will not show it")
    Component(desktop, "Whiska.Desktop", "behaviour", "The desktop's notifier, reached without herdr; one argument per piece of text, never a shell")
    Component(storage, "Whiska.Storage", "Ecto", "Questions, mode, dead mice")
    Component(record, "Whiska.OpenHouses", "text file", "Which houses are open; trusted only while an owl is alive")
    Component(backstop, "Whiska.Backstop", "text file", "How much this house's backstop collected that the idle trigger missed")
    Component(watch, "Whiska.Watch", "renderer", "A row per mouse: branch, pane status, how long it has been going, and the question waiting, the mouse's topic, or its last action")
    Component(ink, "Whiska.Watch.Ink", "renderer", "Plain ANSI for the branch, a waiting question and the elapsed time; never a full reset, so a stale board's dim survives the row")
    Component(snapshot, "Whiska.Watch.Snapshot", "text files", "The board for one house, in ~/.whiska/board/, and the pane it delivers to beside it")
    Component(transcript, "Whiska.Watch.Transcript", "reader", "The last tool call or sentence and how long the mouse has been silent, from its own Claude Code transcript, over Whiska.Transcript")
  }

  ContainerDb(db, "House database", "SQLite", "mice and questions")

  Rel(cliboot, record, "Reads what was open last time")
  Rel(cliboot, sup, "Starts with the repos to open")
  Rel(sup, house, "Opens and shuts")
  Rel(sup, record, "Adds on open, removes on shut")
  Rel(house, herdrb, "Lists panes, subscribes, raises the hoot")
  Rel(herdrb, sock, "Dispatched to the configured implementation")
  Rel(sock, herdrd, "One request per connection; events stream")
  Rel(house, mode, "Judges the queue against it before the gate; notices a change on the board tick")
  Rel(house, draft, "Judges the main pane's screen before typing into it")
  Rel(house, hoot, "Composes and sends the hoot for the question it has just typed")
  Rel(hoot, herdrb, "Asks herdr to show it")
  Rel(hoot, desktop, "Raises it there when herdr's popups are off or nobody is attached")
  Rel(desktop, nc, "Runs the notifier with an argument list")
  Rel(house, doorstep, "Collects")
  Rel(house, backstop, "Marks what only the backstop found; clears it at open")
  Rel(doorstep, entry, "Decodes each JSON file")
  Rel(house, markerq, "Classifies each entry's text")
  Rel(house, storage, "Writes questions, marks mice dead")
  Rel(house, cleanup, "Sweeps on the backstop")
  Rel(cleanup, gitq, "Asks the four preconditions, removes the worktree and the branch")
  Rel(cleanup, herdrb, "Removes a landed worktree and closes its pane, never forced")
  Rel(cleanup, storage, "Stamps the mouse removed")
  Rel(house, pickup, "Sweeps on the backstop, handing it the pane list it already has")
  Rel(pickup, mousepane, "Finds the pane, asks whose worktree it is, reads its box")
  Rel(pickup, herdrb, "One line into the mouse's own pane")
  Rel(house, bell, "Sweeps on the backstop before pickup, with the same pane list")
  Rel(bell, mousepane, "The same bounds pickup types within")
  Rel(bell, herdrb, "The doorbell again, into the mouse's own pane")
  Rel(bell, storage, "Reads the chased answers; counts each ring, marks one not taken")
  Rel(house, hoot, "One hoot for an answer the owl gave up on")
  Rel(mousepane, draft, "Judges the mouse's own screen")
  Rel(mousepane, herdrb, "Which worktrees are this checkout's", "worktree.list")
  Rel(pickup, doorstep, "Is anything of this mouse's still uncollected")
  Rel(pickup, storage, "Reads worked_at, stamps picked_up_at")
  Rel(house, watch, "Renders the board every second")
  Rel(watch, transcript, "What a blocked or stalled mouse is stuck in")
  Rel(watch, ink, "Colours the branch, the question and the elapsed time")
  Rel(house, snapshot, "Writes the board where the statusline will find it")
  Rel(storage, db, "Ecto/exqlite")

  UpdateLayoutConfig($c4ShapeInRow="4", $c4BoundaryInRow="1")
```

## The load-bearing choices

**Pane discovery exists because the subscription is per pane.** Checked against herdr
0.8.2: `pane.agent_status_changed` needs a named `pane_id` and rejects a wildcard, while
`pane.closed`, `pane.exited`, `pane.agent_detected` and `workspace.closed` are global. So a house matches each
pane's `cwd` up to a mouse record's worktree path, records the pane id on the mouse — the
first and only thing that ever fills ADR-0006's `pane` column — and reopens the
subscription whenever that set changes. A dropped connection is retried with a wait, and
kept being retried while herdr is down.

**Three collection triggers, only one a timer.** A mouse pane going idle, the house
opening, and a slow backstop. An idle collection that finds nothing retries after 2 s and
5 s, since the idle event can beat the mouse's `Stop` hook to the doorstep. Collection
reads and marks; it never deletes and never touches the worktree (ADR-0007). Cleanup, on
the same backstop, is the one thing in the owl that does (ADR-0061).

**The backstop is loud about what it finds.** Anything it collects is something the idle
trigger should have brought a minute earlier, so the house warns on stderr and marks it
in `Whiska.Backstop` for `whiska doctor` to read later. Collecting at open does not count
— that is the designed "what landed while the owl was down" path — and neither do the
idle trigger's own retries. Without this, a trigger that never fires looks exactly like a
healthy owl, which is what happened (ADR-0036, note of 2026-09-28).

**The board is written, never asked for** (ADR-0051). Every other second the house lists herdr's
panes, renders a row per mouse and replaces one file; in between it rewrites that file with
only the elapsed times moved on. Nothing is typed into a session to produce it: a mouse's topic rides in on the pane list herdr answers with
anyway, what it is stuck in comes from the transcript Claude Code is already writing
(ADR-0050), and a mouse with neither simply has an empty column.
The statusline script then prints that file and starts nothing, which is what makes a
one-second refresh affordable in every open session at once. The recorded main pane is
written beside it in the same breath, which is how a session finds out whether it is the
one being delivered to without starting anything either (ADR-0065).

**The screen is read in one place** (ADR-0047). herdr has no input signal, so the
delivery gate asks `Whiska.Herdr.read_screen/2` for the main pane's visible screen,
styling included, and `Whiska.Delivery.Draft` finds the box by its frame and decides
whether there is anywhere safe for the line to land, counting Claude Code's faint
suggestion as nothing (ADR-0068). Pickup asks the same question of a mouse's pane and
takes the same answer. The boundary returns
text and judges nothing; the classifier judges text and talks to nothing — the same split
as `Whiska.Question.Marker`, for the same reason (ADR-0031).

**The hoot is composed where the line is** (ADR-0062). A delivered question raises one
desktop notification, and `Whiska.Delivery.Hoot` builds it out of the same
`Whiska.Delivery.Text` functions that build the line, so there is one phrasing of one
event rather than two. The house sends it with `Whiska.Delivery.Hoot.send_out/4` in the
same branch that typed the line. That asks herdr first and, when herdr says its popups are
off or nobody is attached, raises the same hoot through `Whiska.Desktop`
(ADR-0071). Whatever comes back is swallowed: the question is
already recorded sent, and an owl that crashed on a failed notification would lose the
thing the notification was about. `whiska doctor` is where the outcome is read, from a hoot
it sends itself down the same path.

**Classification is the marker and nothing else** (ADR-0009). `Whiska.Question.Marker`
reads the last marker line — a line of invisible separators, three for `done` and two for
`needs-decision`, or the older `[worktree-status: …]` spelling — and maps it to `done`,
`needs-decision` or `unmarked`; anything unrecognised is `unmarked`, which is delivered.
Only that one line is read, and only that one line is stripped before the person sees the
message, so a marker quoted mid-prose survives intact.

**The hook does not classify.** `Whiska.Hook.Stop` writes the raw final message and exits;
the owl reads the marker on collection. That keeps the writer dumb and puts the one piece
of judgment on the side that can be changed without touching every mouse's `settings.json`.

**A `done` report skips the queue and closes at once** — typed as "finished" with no
reply command, ahead of whatever is waiting and with no regard for the delivery slot,
and closed as soon as the prompt lands (ADR-0009 revised 2026-09-27, ADR-0008's note of
2026-10-01). An entry whose worktree is gone is settled or orphaned by its branch
(ADR-0064):
recorded, surfaced, never interrupting, because there is nowhere to reply and nothing
left to change.

**Nothing here crosses houses.** A house types into its own main session and nowhere
else. Until 2026-09-29 one process did reach across — `Whiska.Owl.Nudge`, which typed
`⚡ <folders> waiting` into every other open house's main session so its statusline would
redraw — and ADR-0044 deleted it: that line arrived as a user turn the other session's
Claude could not tell from a prompt. What is waiting in another repo now reaches the
person through the machine-wide line herdr's tab bar draws, which reads every recorded
house off disk on its own timer (ADR-0048). The open-houses record is still written by the owl and
still read, but only by the statusline and the doctor asking questions, never by anything
acting.

**Cleanup asks this machine first and herdr last** (ADR-0061). Each mouse is judged by what
git and the house's own database can answer alone — the branch merged into the base, the
worktree clean, nothing unpushed, and the mouse quiet: its last word a `done` report,
nothing of its open or sent, nothing of its left uncollected on the doorstep. Only once
something has passed all of that is herdr asked anything, so a house with nothing landed
opens no socket. herdr then supplies the last two facts — what is sitting in the worktree, by
each pane's own working directory rather than by the record's remembered pane id, and
which workspace the worktree is open in, which have to agree with each other — and
performs the removal: one `worktree.remove`
with `force: false`, which takes the worktree and the pane together the way `drop-worktree`
always has. Anything unknown — a detached head, an unnameable base, a silent herdr, a live
pane whose workspace herdr does not name — leaves the worktree standing. It is the first
thing in Whiska that deletes anything, and the first that can close a session.

**Every landed branch is noted, torn down or not.** The same sweep stamps `landed_at` on
a mouse the first time it sees the base reach that branch's work through a merge — from
the worktree's own head while it stands, from the branch ref in the main checkout once it
has gone (V005, ADR-0064). An ancestor of the base is not enough on its own: a branch cut
an hour ago is one too. Nothing is removed on the strength of the stamp; it is what later
decides whether a question that mouse left waiting is `settled` or `orphaned`, and
collection reads it too, for an entry arriving after its worktree has gone.

**Dead mice are marked, not deleted.** `pane.closed` or `pane.exited` on a known mouse
pane stamps `died_at` (the V002 migration's one column) and cascades that mouse's open
*and sent* questions out of the queue (ADR-0026, ADR-0007) — the sent one because it holds
delivery's one slot and nothing can answer it any more. They go to `settled` when the
branch landed and `orphaned` when it did not (ADR-0064). A mouse with no pane anywhere at
house open is dead too, found by reconciling against `pane.list`; delivery is attempted
straight after, so a slot freed that way does not wait for the backstop. The same
reconciling runs when `workspace.closed` arrives, since herdr closes a dropped worktree's
workspace without a `pane.closed` for its panes, and the board is redrawn on the spot.

**Pickup is cleanup's mirror image, and runs on the same tick** (ADR-0067). Cleanup asks
whether a branch is finished with; pickup asks whether a turn ended without finishing.
Both are judged from what this machine already knows — the doorstep, the mouse record,
the pane list the house re-listed a moment earlier — and both treat unknown as a refusal.
The difference is what they do with the answer: cleanup takes a session away, pickup
makes one work. Pickup is one of two things in Whiska that type into a pane that is not its
house's main session, and it does so once per dead turn.


**The doorbell is the other, and it rings for the person's own answer**
(ADR-next-an-answer-is-taken-not-typed). `whiska reply` saves the answer and rings once;
the mouse's own `UserPromptSubmit` hook hands the answer over and stamps it taken. A
doorbell herdr accepted can still be swallowed, and only the missing stamp says so, so on
the same tick `Whiska.Doorbell` rings again for every answer saved and not taken — at
least 90 s apart, at most three times, within exactly the bounds pickup types within
(`Whiska.MousePane`), never into a held mouse. Each ring is counted before it is typed and
put back if herdr refuses, the order pickup's cap uses. After the third, the answer is
marked not taken once and the house raises one hoot; the board row, `inbox` and `whiska
questions` say so until the mouse takes it. Pickup leaves such a mouse alone: its next
turn never began.
