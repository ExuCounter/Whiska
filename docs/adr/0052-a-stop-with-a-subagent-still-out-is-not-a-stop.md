# A stop with a subagent still out is not a stop

ADR-0049 made finishing a pipeline the mouse runs, and its third step sends reviewers over
the change as subagents. Claude Code runs a subagent in the background: the `Agent` call
returns at once, the mouse's turn *ends*, and the session is woken again when the subagent
reports. The `Stop` hook fires on every one of those endings.

So a mouse doing exactly what the finish part asks produces turns like "Still waiting on
the three reviewers." — no marker, because the mouse is not finished and is not asking the
person anything. ADR-0009 says an unmarked stop is delivered, and it was: five times on
2026-09-29 alone (questions #44, #45, #57, #58, #66), each one a question that asked
nothing.

No instruction can prevent this. The mouse cannot choose not to end that turn; the harness
ends it. ADR-0049's own wording — "a turn that is neither finished nor asking for a
decision does not end at all" — described a rule the model was never in a position to
follow, and is trimmed as part of this decision.

## Decision

**The `Stop` hook reads the transcript Claude Code hands it and writes nothing when the
mouse has a subagent still out.** It exits 0 quietly: nothing on the doorstep, no entry, no
question. The session will be woken when the subagent reports, and the turn that really
does finish writes the marker and the report as always.

**What "still out" means is read from the transcript, not guessed.** Checked against a real
transcript on 2026-09-29 (`~/.claude/projects/…/29421db1-….jsonl`):

- A background `Agent` call gets its `tool_result` within milliseconds. It carries no
  result, only `agentId: <id>` and "the agent is working in the background".
- The report arrives later as a user entry Claude Code stamps
  `origin: {"kind": "peer", "handback": true, "from": "<id>"}`.

An id launched and not handed back is a subagent still out. **A pending `tool_use` is
therefore the wrong signal** — the obvious reading, and the one this work started from.
Every `Agent` call has a result almost immediately; what is pending is the hand-back.

**Both ends are read structurally, because prose in a transcript is not evidence.** A
`tool_result` counts as a launch only when it answers an `Agent` call seen in the same
tail — otherwise any shell output, fetched page or file that happened to contain a line
reading `agentId: something` would register a launch that could never be handed back, and
silence the mouse for hours.

**A hand-back is read in every shape it arrives in, and from the queued copy as well as
the live one.** Amended 2026-09-30, after the shape this originally missed silenced a
mouse for four hours. Three shapes, checked against
`~/.claude/projects/…/7453bb5e-….jsonl`:

- the `origin` stamp above;
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

**A launch older than half an hour is abandoned, not pending.** The deadline the
Consequences below predicted, in its cheapest form: an aged launch stops being counted
rather than forcing a write. Long enough that no reviewer this repo runs comes near it,
short enough that a lost hand-back costs one quiet stop rather than a night of them. A
launch whose entry carries no readable timestamp cannot be aged and holds the turn as
before.

**A turn the person started clears the accounting.** `origin: {"kind": "human"}` — they
typed. Whatever was out at that moment they may well have interrupted, and an agent that
will never report must not be able to hold a mouse silent indefinitely. The cost is that a
person who types while reviewers really are running gets the next stop delivered; that is
noise, which is the direction this whole decision fails in on purpose.

**Only the mouse's own entries count.** A subagent's entries are marked `isSidechain`, and
what it launches is its own business.

**Unreadable means deliver.** A missing `transcript_path`, a file that is gone, a path that
is not a plain file, a line that will not parse, a tail that starts after the launch —
every one of them counts as nothing out, and the stop is written as it always was. This is
ADR-0009's direction held: being wrong towards noise costs a ping, being wrong towards
silence loses a mouse.

## Consequences

**Whiska now reads a turn to decide whether to record it, which is new.** Every other part
of ADR-0009 stands: the hook still does not classify, still has no opinion about the
message, still writes unconditionally once it decides the turn happened. What it decides is
narrower — *did this turn end?* — and it decides it from a fact in Claude Code's own file
rather than from the text of the message. A hook reading the message to guess whether the
mouse meant to stop is exactly the heuristic ADR-0009 refuses, and is not what this is.

**A subagent that never reports takes its mouse with it for half an hour.** A lost
hand-back, an agent that errors out, an interrupted turn: the launch stays unmatched and
every stop after it is swallowed. It proved real the day this was written, so the deadline
is now in: the launch ages out, the person's next prompt still clears the accounting, and
the launch still scrolls out of the tail. The cost the other way is one delivered progress
note from a reviewer that genuinely runs longer than that, which is the direction this
whole decision fails in on purpose.

**The check runs only for a mouse.** It sits after the worktree has been resolved, so the
main session and any repo Whiska is merely installed in read no transcript at all.

**Only the tail is read, and generously: 512 KB.** `Stop` fires once per turn, not every
two seconds like the board (ADR-0050), so the budget can be large enough to hold a whole
turn's launches. A tail that starts after a launch reads as nothing out, which is the safe
direction above.

**The transcript is load-bearing in a second place now.** ADR-0050 already accepted that
the format is somebody else's and can change under us; there the cost was an empty column
on the board. Here the cost is this bug coming back — and it did, the day after, through a
hand-back shape this decision had not seen. A Claude Code release that renames `agentId`
makes every mid-turn stop a question again: loud, not silent, and the same failure that
exists today. The shape that fails the other way is a launch Whiska can still see paired
with a hand-back it no longer recognises, and that is the one that actually happened. Three
guards against it, in order of how much they are trusted: the hand-back is read in three
shapes and from both the live and the queued entry, the person's next prompt clears the
slate, and a launch old enough stops counting whatever else is missing.

**`Whiska.Transcript` is now the one reader of Claude Code's JSONL.** The folder name, the
tail and this test live there; `Whiska.Watch.Transcript` keeps the board's reading of it and
delegates the file handling.

## Considered options

**Have the mouse write something the hook can recognise.** A sentinel line meaning "not
finished, do not deliver". Rejected for the reason the bug exists: this is a class of turn
the model does not reliably know it is in, and one more marker to forget is one more way to
be delivered unmarked.

**Deliver it as a notice rather than a question.** Cheaper, and still wrong: the person does
not want to be told five times that reviewers are running.

**Leave it, and let the person ignore the noise.** What happened for a day. It costs the
delivery slot (ADR-0008) — every mid-turn stop holds it until the person clears it, so a
real question from another mouse waits behind a progress note.
