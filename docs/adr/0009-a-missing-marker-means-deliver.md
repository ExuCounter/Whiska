# A missing marker means deliver; `done` is delivered too, and never waits for an answer

When a mouse finishes a turn, Whiska classifies the message purely by the marker the mouse
itself wrote. No heuristics, no extra filtering, no model reading the text to decide. This
is the same "Whiska stays dumb" line drawn everywhere else: judgment belongs to the mouse
and to the human, not to the router.

The first version of this decision defined two markers — `done` and `needs-decision` — and
left their absence undefined. That was the wrong default, and this ADR supersedes it. A
model cannot be relied on to emit an exact marker every single time, so the question is
which way that failure should break. Under the old scheme a forgotten marker meant a mouse
sat waiting and nobody was ever told. **A marker is now required to be quiet, not to be
heard.**

- **No marker at all → deliver.** The mouse stopped and did not say why; that is worth
  interrupting for.
- **`done` → delivered, then closed at once.** Told as "finished", with no reply offered
  (revised 2026-09-27; see below — it was "recorded, never delivered" before).
- **`needs-decision` → delivered.** Still valid, now redundant, since absence says the
  same thing.

## Consequences

**Forgetting is the safe direction.** A mouse that forgets its marker makes noise instead
of vanishing. This is the direction every comparable decision in this design already takes:
ADR-0012 errs broad on push detection because "a false 'are you sure?' costs nothing; a
missed real push does", and ADR-0034 reasons identically about which way to be wrong.

**An unmarked stop becomes an ordinary question**, carrying the mouse's full final message
as its body, flagged as having arrived unmarked. It is answered and replied to like any
other. Delivering it as a non-blocking *notice* instead was considered and rejected: a
notice tells you something is wrong and then leaves you to go and find the mouse yourself,
whereas a question gives you a reply channel straight back into its pane — which is exactly
what a mouse that stopped for an unstated reason needs. It also keeps one code path rather
than two delivery kinds with different rules.

That an unmarked question occupies ADR-0008's delivery slot is the gate working as
designed, not a pathology: the gate exists to serialise, and a mouse that stopped without
explaining itself is more likely to need attention than one that asked politely.

**The invisible-character trick stops being load-bearing.** The marker is still prefixed
with an invisible Unicode character so it never appears when reading the transcript. The
risk flagged originally — that a model will not reliably emit it — now costs an unwanted
ping rather than silence, which is a cost worth paying rather than a hole.

`WHISKA_DEBUG=1` renders the marker visibly and logs what the hook read, for the times the
invisible character is the thing under investigation. Deliberately an environment variable
and not a "debug mode": *mode* already means a mouse's build-or-sniff state (ADR-0018), and
one word for two unrelated things is what `CONTEXT.md` exists to prevent.

**A `done` report is delivered like any other question, and closed the moment it is
sent.** This revises the original decision, which closed it on arrival and never delivered
it. In practice that meant a finished mouse vanished: its whole final report sat in the
house, readable only by someone who already knew to run `whiska questions <id>`, and the
person learned a branch was ready by going to look. The marker rule in `CLAUDE.md` asks
mice to write the complete report in the body precisely so that it is read, and a report
nobody is told about is a report nobody reads.

So `done` now reaches the main session as `🐱 feat-x finished · #N`, offering no answer.
It does not wait for a reply: the owl closes it as soon as the prompt lands, so it never
holds ADR-0008's one delivery slot — and, since 2026-10-01, never waits for that slot
either; it goes ahead of whatever is queued. ADR-0008's note of that date has the
reasoning. That keeps one code path — a `done` is a question in
storage and in delivery, differing only in the verb and in what happens after it is
sent — rather than a second "notice" kind with its own rules, which is the trade the
unmarked case already made above. `done` is still the marker for "nothing needed from
you": it changes the line's verb and drops the reply, not whether you hear about it.

**Recording that an entry arrived unmarked is deliberate.** It is the evidence that shows
which mice forget and how often, and therefore whether the invisible-character marker is
worth keeping at all.

## Note, 2026-09-28: the line carries no command

The line shown above used to end in `read: whiska questions N`, and a `needs-decision`
line in `answer: whiska reply N "..."` besides, so the person could see what to type
next. Both were dropped: they made the line read like code. The shape is now `🐱 <branch>
<verb> · #<id> · "<pointer>" · <n> more open`, and the `whiska-delivered` skill that
`whiska init` installs (ADR-0022) recognises it and runs the read. The id stays because
answers are keyed to it (ADR-0005). What this ADR decides — that `done` is delivered,
told as "finished", and closed at once — is unchanged.

## Note, 2026-09-29: the marker is invisible, and only its own line is read

The marker was a readable line, `[worktree-status: done]`, optionally behind one
invisible character. The prefix hid nothing — the words still printed in the mouse's
pane on every single turn, which is noise the person has to read past forever.

Every readable way of hiding it was tried for real, in a throwaway Claude Code pane
(v2.1.277) with a `Stop` hook logging the payload: an HTML comment, a link reference
definition (`[worktree-status]: done`), the `[//]: # (…)` comment trick, `<span
hidden>`, a footnote definition and `<details>`. All six printed verbatim. The
transcript does render markdown — `**bold**` came out styled, asterisks gone — but it
passes HTML and reference lines through as text, and the docs describe no form that is
dropped. The `Stop` payload carried every candidate exactly, so the hook was never the
constraint; the renderer was.

The one thing that does not print is a line made only of characters that draw nothing.
So the marker is now **a last line of U+2063 (INVISIBLE SEPARATOR) and nothing else:
three for `done`, two for `needs-decision`.** A `needs-decision` pointer can no longer
ride on the marker's line, so it moved to the readable line above — it is content, the
person reads it in the pane like any other sentence, and nothing has to strip it back
out.

**What this costs.** The marker is now unreadable to a person and to anyone debugging
it, and a model reproducing exact invisible codepoints is less dependable than one
typing a word. That risk is the one this ADR already priced: a garbled marker arrives
`unmarked` and is delivered loudly, never swallowed, and the count of unmarked arrivals
is the evidence for whether this was worth doing. Claude Code strips invisible
characters from what is *typed into* it ("Removed 1 invisible character"), which does
not touch a mouse's output but is a fair warning about how much the product likes them.

**The bracket spelling is still read** — a turn already in flight, and every message
already stored, keep classifying. Nothing writes it.

**Only the last marker line counts**, for classification, for the pointer and for the
strip. It used to be every occurrence anywhere in the text, which blanked a marker a
mouse had merely quoted mid-sentence — a report about this very grammar came out full
of holes. Every other line is now left exactly as written.

One thing the invisible marker makes possible that the readable one did not: text a
mouse merely quotes — a fetched page, a file printed verbatim — could end in exactly
two or three separators and be read as a marker, with nothing on screen to give it
away. No guard is added for it. Guessing which lines a mouse meant is precisely the
heuristic this ADR refuses, the worst case is a turn closed as finished rather than
one lost, and a mouse that ends its report by pasting raw bytes has a bigger problem
than its marker.

## Note, 2026-09-29: an unmarked stop still means deliver, but a mid-turn stop is not a stop

ADR-0052 narrows what counts as a stop worth recording: when the mouse has launched a
background subagent and has not been handed its report, the `Stop` hook writes nothing and
exits quietly. Claude Code ends a turn every time it waits on a subagent, and the finish
pipeline (ADR-0049) launches three of them, so every finished piece of work was producing
several unmarked questions that asked nothing.

Nothing here is softened. The hook still does not read the message, still has no opinion
about the marker, and an unmarked turn that really did end is delivered as loudly as
before. What it now decides — from Claude Code's own transcript, not from the text — is
whether the turn ended at all. Everything it cannot read counts as ended, so the direction
this ADR chose is the direction the new rule fails in too.

## Note, 2026-10-06: `done` means the brief is done, and the picker reads the branch

A mouse told to write a failing test first did, stopped with it uncommitted, and ended on
`done`. The finished picker recommended landing a branch with nothing committed, and
landing the test would have broken CI. Two things change; neither is classification.

- **`done` is for a finished brief.** A turn that stops short of the brief on purpose — a
  failing test written first, an answer to a question asked mid-task — ends on
  `needs-decision`, and its option A names the concrete next step. The marker's meaning
  sharpens; the two markers, and the owl's reading of them, do not move.
- **`whiska show` says what a finished branch holds**, on the line under the heading:
  commits beyond the base, counted as Land here lists them, and files not committed, or
  `unknown` when git cannot say. The finished picker in `whiska-delivered` offers what
  fits — a commit first, then a landing or a request, for a branch with files not
  committed; no landing for a branch with nothing on it. Whiska reads git, never the message: the turn is still
  classified by its marker alone, and the line only tells the main session what the
  branch it is about to offer a finish for actually holds.

A third marker for "stopped short" was rejected: it would change the parser, the line,
the hoot and the board, and still need a way to say "carry on". Recording the branch in
the `Stop` hook was rejected too: it needs stored data, and the picker needs the branch as
it is when the person picks, not as it was when the turn ended. What neither layer
catches — a failing test that was committed, a mid-task answer on a branch that already
has commits — looks ready to land, and the mouse's marker is the only guard there.

**Changed the same day: files not committed are offered a commit, not the next step.** As
first written, a branch with only uncommitted files was offered "the next step" first, read
as a mouse that stopped short. Measured across this machine's mice, 29 of 126 finished
turns that changed files ended with changes not committed — 24 never committed at all —
because nothing asked a mouse to commit and Claude Code commits only when asked. With the
marker rule above in force, `done` beside files not committed is far more often finished
work nobody committed than a mouse that stopped short, and "carry on with your brief" sent
to a mouse that believes it is done asks it for nothing.

So every branch line listing files not committed, with commits or without, is offered
Commit and land (recommended), Commit and open a PR, Chat further and Drop it. The main
session commits in the mouse's worktree, after the option's preview has listed every file,
with a message passed by file: no mouse text on a command line (ADR-0074). Text typed into
"Other" still reaches the mouse. ADR-0049's note of this date makes the mouse commit before
it finishes, so this is the fallback for one that did not.

The cost: a mouse that stopped short and still ended on `done` has its half-done work
committed and landed. The tests Land here runs catch a failing test and keep the worktree,
but the cherry-pick is on the local current branch by then, as with any landing.
