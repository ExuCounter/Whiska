# A stop with background work still out is not a stop

ADR-0049 made finishing a pipeline the mouse runs, and its third step sends reviewers over
the change as subagents. Claude Code runs a subagent in the background: the `Agent` call
returns at once, the mouse's turn *ends*, and the session is woken again when the subagent
reports. The `Stop` hook fires on every one of those endings. A test suite run in the
background, a reviewer restarted with `SendMessage`, a `Monitor` or a `Workflow` end the
turn the same way.

So a mouse doing exactly what the finish part asks produces turns like "Still waiting on
the three reviewers." — no marker, because the mouse is not finished and is not asking the
person anything. ADR-0009 says an unmarked stop is delivered, and it was: five times on
2026-09-29 alone (questions #44, #45, #57, #58, #66), each one a question that asked
nothing. And twice on 2026-10-14: #548 waited on a background test run and a restarted
reviewer, which this decision did not yet count, and #555 on reviewers launched further
back than the hook read.

No instruction can prevent this. The mouse cannot choose not to end that turn; the harness
ends it. ADR-0049's own wording — "a turn that is neither finished nor asking for a
decision does not end at all" — described a rule the model was never in a position to
follow, and is trimmed as part of this decision. (A *marked* stop is different: the mouse
chose to write the marker, so a brief line is a soft guard there, under the hook's hard one.)

## Decision

**The `Stop` hook writes nothing when the stop carries no marker and the mouse has
background work of its own still out.** It exits 0 quietly: nothing on the doorstep, no
entry, no question. The session will be woken when that work reports, and the turn that
really does finish writes the marker and the report as always. **A marked stop with a
subagent of its own still out is held, not dropped** (below).

**A marked stop is written beside any work but a subagent.** A mouse that asks something, or
reports done, beside a dev server or a test watcher has said what it is waiting on. Replayed
over 1,509 stops of this machine's mice on 2026-10-14: holding every stop with any work out
would have swallowed 31 marked stops. The 10 unmarked stops the wider reading newly passes
over were all a mouse waiting on its own work.

**A marked stop is held while a subagent is out, and delivered when its turn is over** (changed
2026-10-15). On 2026-10-15 #626 ("needs a decision": "The reviewer is still running") and
#627 ("finished": "Two reviewers are still running, and I haven't committed") were
delivered: each mouse said what it was waiting on, in a marker that claims the opposite — a
finished report or a question, with its own reviewers still reading the change. Replaying
the guard on both transcripts said in flight (one `Agent` and a `Monitor`; two `Agent`); only
the marker gate let them through. The mouse's own reviewers are the one case where `done` or
`needs-decision` is wrong by construction, so a subagent out holds a marked stop too. But a
question a mouse asks while a reviewer runs is real, and this decision's first form lost 6 of
them, so a held stop is delayed, never dropped:

- The hook writes it to the doorstep as a **held** entry (`.held`, beside the `.json` ones),
  which nothing that counts or lists what waits reads (ADR-0036).
- **It ends when the mouse's next turn does.** A reviewer reporting wakes the mouse, and
  its next stop settles the held one, read by the hook: a *marked* stop supersedes it, as any
  stop supersedes the mouse's earlier questions (ADR-0007), and the held one is dropped; an
  *unmarked* stop is the mouse not asking again, so the held one's words are delivered in its
  place, with the unmarked turn's own spec, plan, model and time, and the unmarked message
  is not written; a stop passed over, or held again, changes
  nothing, the newer held one replacing the older.
- **Otherwise the owl releases it,** at the start of every collection (the idle trigger,
  the backstop, opening the house), when no subagent of the mouse is out *and* its turn has
  ended — the transcript's last entry is still the mouse's own word, which a mouse woken by
  the report and working on it has not got, and the file has been quiet for the settle
  window (two minutes, ADR-0067's): a mouse's text and the tool call after it are separate
  entries, and between them it looks finished and is not. So a held stop is never delivered while its
  mouse is working on the findings, and never dropped without a newer stop of the mouse's
  own. A reviewer that never reports, or never wakes the mouse, delays it until the launch
  is half an hour old; a mouse still working half an hour after the stop gets it delivered
  anyway. A transcript that cannot be read releases it at once. A released entry is
  collected like any other and is no missed trigger for the backstop's count.

The price: a question held while a reviewer runs waits for it, and for the mouse's turn, up
to the half hour. A person who interrupts the woken mouse, or a compaction, leaves the
transcript's last entry something other than the mouse's word, so the held stop waits out
the half hour too. And a mouse that forgets the marker on a real question in its next turn
has the held stop delivered instead of it: the question it asked then is in the pane, not
on the doorstep. The build and review briefs tell a mouse to wait for its reviewers' reports and then say what it
had to say, so the held entry is the net, not the plan. Every other kind of work still leaves
a marked stop written.

**What "still out" means is read from the transcript, not guessed.** A launch the mouse
made and has not had back:

- A background `Agent` call gets its `tool_result` within milliseconds. It carries no
  result, only `agentId: <id>` and "the agent is working in the background" (checked
  2026-09-29, `~/.claude/projects/…/29421db1-….jsonl`). **A pending `tool_use` is
  therefore the wrong signal**, the obvious reading and the one this work started from:
  what is pending is the report.
- Every other kind is read from the structured result Claude Code records beside the call,
  `toolUseResult` (checked 2026-10-14): `backgroundTaskId` from `Bash` run in the background
  or moved there at its timeout; `resumedAgentId` from `SendMessage` restarting a subagent
  that had already reported, which is out again; `taskId` from `Monitor`, unless
  `persistent`, since a monitor that lasts the session is never waited on; `taskId` from
  `Workflow`.
- A forked `Skill` is not background work: all 68 seen here finished inline and never
  reported.

**Both ends are read structurally, because prose in a transcript is not evidence.** A
result counts as a launch only when it answers a call, seen in the same tail, to the tool
that writes that shape — otherwise any shell output, fetched page or file reading
`agentId: something`, or another tool's `taskId`, would register a launch that could never
be handed back, and silence the mouse.

**A report is read in every shape it arrives in, and from the queued copy as well as
the live one.** The shape the first version missed silenced a mouse for four hours.
Three shapes, checked against
`~/.claude/projects/…/7453bb5e-….jsonl`:

- the `origin` stamp `{"kind": "peer", "handback": true, "from": "<id>"}`;
- the `<agent-message from="<id>">` frame;
- the `<task-notification>` frame, whose id sits in `<task-id>`.

The frames are not a fallback for a missing stamp. The commonest shape of all carries
`origin: {"kind": "task-notification"}` — a stamp that says a report arrived and not which
agent sent it — so the id has to come from the frame.

And a report that lands while the mouse is busy is *queued*. Claude Code records the
queued copy as an entry of type `attachment`, with the frame in `attachment.prompt` and
the `origin` stamp — when there is one — on the attachment rather than the entry. It never
writes the `user` entry this decision originally looked for. So the stamp and the frames
are both read from an `attachment` exactly as from a `user` entry, and a frame is read
only from those two: an assistant message quoting one is the mouse talking about a report,
not the report.

**Two notifications are not reports.** A subagent that stopped with work of its own still
running notifies with a `<note>` saying so, and that "the result below may be interim"; the
same id notifies again when it is done. A `Monitor` notifies once per event it sees, with no
`<status>`; its report is the notice that carries one when its stream ends, or the event
Claude Code writes when it expires, "[Monitor expired after …]". Anything from `<result>` or
`<event>` on is the work's own output and is never read for these, so a report quoting the
interim note is still a report.

**`TaskStop` ends whatever it names, reported or not.** Of 22 tasks stopped on this
machine, 5 notified afterwards. An agent the person stops notifies with `<status>killed</status>`
under its own id, which is a report. A session restarted with work out names every task it
lost in one notice, a `<task-id>` line each before anything else in the frame, and every
one of them is back (seen 2026-10-15).

**A launch older than half an hour is abandoned, not pending,** whatever its kind. The deadline the
Consequences below predicted, in its cheapest form: an aged launch stops being counted
rather than forcing a write. Long enough that no reviewer this repo runs comes near it,
short enough that a lost hand-back costs one quiet stop rather than a night of them. A
launch whose entry carries no readable timestamp cannot be aged and holds the turn as
before.

**A turn the person started clears the accounting; a line Whiska typed does not**
(changed 2026-10-16). `origin: {"kind": "human"}` — they typed. Whatever was out at that
moment they may well have interrupted, and an agent that will never report must not be able
to hold a mouse silent indefinitely. The cost is that a person who types while reviewers
really are running gets the next stop delivered; that is noise, which is the direction this
whole decision fails in on purpose. But Claude Code stamps the lines Whiska types into the
pane the same way, and those interrupt nothing: on 2026-10-16 the letter `whiska send`
typed cleared #657's two running reviewers, and the mouse's next note arrived as a stop
with no reason, as three others had in three days. So Whiska's own lines keep the
accounting: the letter line, the doorbell, the review round's line, the pickup and the
lifted-hold line, each told apart by its text, matched against the code that types it, a
letter's path by the shape of a letter's name (`Whiska.Send.line?/1`,
`Whiska.Doorbell.line?/1`, `Whiska.ReviewRound.line?/1`, equality for the two fixed
ones). Only the person's own typing clears it.

**The mouse's plain reply to a letter or an answer is written whatever runs.** The person
must be able to ask a mouse something while its reviewers run. The turn after a letter or
doorbell line, while the work out is only what was out when that line came, is the mouse's
reply: an unmarked one is left as a **reply**, recorded closed, waiting on nobody, typed
whatever its mouse said or did since. Its line goes next once the slot is free when the
letter took a sent question's place, as any letter's reply does (ADR-0008), else once
nothing waits, like a finished report (ADR-0009). A marked one is held like any other
while a subagent is out: the build brief tells a mouse the hook holds a finished report or
a question until its reviewers report, and a "Ready to push?" or a "Ready to merge" beside
a running security reviewer could be answered, or landed, before it reports (the person
chose this on 2026-10-16). A reply settles no held stop and supersedes nothing: what the
mouse asked before it still stands, and a held one waits for the turn after the work.
Work launched since the line and still out, or a report waking the mouse (a `user` entry
with an `origin`, or one with none that carries a report; one queued while it is busy
wakes nothing), ends the reply, and every stop after that follows the rules above. The
pickup and lifted-hold lines carry a reply on only when the reply's own turn died on an
API error; otherwise they, and the review round's line, make none: they carry no words of
the person's. The board shows a written reply beside its work as that work running, and
never as stuck: the stop was written, not passed over.

**Only the mouse's own entries count.** A subagent's entries are marked `isSidechain`, and
what it launches is its own business.

**Unreadable means deliver.** A missing `transcript_path`, a file that is gone, a path that
is not a plain file, a line that will not parse, a tail that starts after the launch —
every one of them counts as nothing out, and the stop is written as it always was. This is
ADR-0009's direction held: being wrong towards noise costs a ping, being wrong towards
silence loses a mouse.

## Consequences

**Whiska now reads a turn to decide whether to record it, which is new.** The hook reads
one thing of the message, whether it carries a marker at all, with the classifier the owl
uses (ADR-0009), and one fact from Claude Code's own file. What it decides is narrow — *did
this turn end?* A hook reading the message to guess whether the mouse meant to stop is
exactly the heuristic ADR-0009 refuses, and is not what this is.

**Background work that never reports holds its mouse quiet for half an hour.** A lost
hand-back, an agent that errors out, an interrupted turn: the launch stays unmatched and
every unmarked stop after it is swallowed, and every marked one while it is a subagent is held. It proved real the day this was written, so the
deadline is in: the launch ages out, the person's own next prompt still clears the accounting,
and the launch still scrolls out of the tail. Meanwhile the board shows the mouse working,
then `✖ stuck` (ADR-0082); nothing is delivered on its behalf, which the person chose on
2026-10-14 over delivering the swallowed stop. herdr keeps a pane working only while a
subagent is out, so for any other kind the board reads the passed-over stop from the
transcript itself: an idle mouse whose last word is held by work unreported — unmarked beside any work, marked beside a subagent. Its
last word is the last message it wrote; an API error Claude Code wrote in its place is a
turn that died, not one passed over. The cost the other way is one delivered
progress note from work that genuinely runs longer than that, which is the direction this
whole decision fails in on purpose.

**A mouse whose last stop was passed over is never picked up (ADR-0067),** even once its
work is half an hour old. Its quiet pane is a wait, not a turn that died, and the owl's
line would tell it that it died on an error.

**The check runs only for a mouse.** It sits after the worktree has been resolved, so the
main session and any repo Whiska is merely installed in read no transcript at all.

**Only the tail is read, and generously: 4 MB.** Across 871 launches on this machine on
2026-10-14 the median sat 68 KB before its report, the 99th percentile 878 KB and the
furthest 1.54 MB; 34 sat beyond the 512 KB this read began with, which is how #555 was
delivered. Reading and checking 4 MB costs about 21 ms. `Stop` fires once per turn, not
every two seconds like the board (ADR-0050), which reads this tail only for a working mouse
quiet ten minutes and an idle one with nothing to say, once per change to the file
(ADR-0082). A tail that starts after a launch reads as nothing out, which
is the safe direction above. Compaction writes `task_status` entries for work still running;
they are not read, since the tail already reaches past every gap measured.

**The transcript is load-bearing in a second place now.** ADR-0050 already accepted that
the format is somebody else's and can change under us; there the cost was an empty column
on the board. Here the cost is this bug coming back — and it did, the day after, through a
hand-back shape this decision had not seen. A Claude Code release that renames `agentId` or
`backgroundTaskId` makes every mid-turn stop a question again: loud, not silent, and the same failure that
exists today. The shape that fails the other way is a launch Whiska can still see paired
with a hand-back it no longer recognises, and that is the one that actually happened. Three
guards against it, in order of how much they are trusted: the hand-back is read in three
shapes and from both the live and the queued entry, the person's own next prompt clears the
slate, and a launch old enough stops counting whatever else is missing.

**`Whiska.Transcript` is now the one reader of Claude Code's JSONL.** The folder name, the
tail and this test live there; `Whiska.Watch.Transcript` keeps the board's reading of it and
delegates the file handling.

## Considered options

**Have the mouse write something the hook can recognise.** A sentinel line meaning "not
finished, do not deliver". Rejected for the reason the bug exists: this is a class of turn
the model does not reliably know it is in, and one more marker to forget is one more way to
be delivered unmarked. Weighed again on 2026-10-14 and rejected again: a forgotten one
still delivers, and a wrong one silences a mouse that really is asking.

**Ask herdr whether the pane is still working.** herdr does keep a pane working while a
subagent is out, but every pane reads working at the moment its `Stop` fires, so the hook
cannot ask; the owl would have to hold each entry until the pane settled, inside delivery,
to learn what the transcript already says.

**Hold every stop with work out, marked or not.** Rejected on the replay above: any work,
not only a subagent, swallows 31 marked stops. For a subagent alone it was this decision's
first form, rejected then for swallowing 6 questions and taken up on 2026-10-15 for #626 and
#627 — with the stop held, not dropped, so that those questions are late and not lost.

**Deliver it as a notice rather than a question.** Cheaper, and still wrong: the person does
not want to be told five times that reviewers are running.

**Leave it, and let the person ignore the noise.** What happened for a day. It costs the
delivery slot (ADR-0008) — every mid-turn stop holds it until the person clears it, so a
real question from another mouse waits behind a progress note.

Changed on 2026-10-12: the board reads this same tail too, on every rebuild, for a working mouse quiet ten minutes (ADR-0082, changed 2026-10-15).
Changed on 2026-10-15: a marked stop is held too while a subagent is out, and it is delivered once none is out and the mouse's turn has ended, settled by the mouse's own next stop, or after the half hour; the board and the owl's pickup read it as passed over.
Changed on 2026-10-14: only an unmarked stop is passed over; every kind of background work counts, not only subagents; the tail is 4 MB; an interim report and a monitor's event are not reports, and `TaskStop` is one; the board and the owl's pickup read a passed-over stop from the transcript.
Changed on 2026-10-16: a line Whiska typed keeps the accounting, and the mouse's unmarked reply to a letter or an answer is written as a reply, whatever earlier work still runs; a restart's notice hands back every task it names.
