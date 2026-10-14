# A missing marker means deliver; `done` is hooted, never delivered

When a mouse finishes a turn, Whiska classifies the message by the marker the mouse itself
wrote and by nothing else: no heuristics, no model reading the text. Judgment belongs to
the mouse and to the person, not to the router.

- **No marker → deliver.** The mouse stopped and did not say why; that is worth
  interrupting for. The question arrives like any other, carrying the whole final message,
  flagged as having arrived unmarked.
- **`done` → recorded closed and hooted, never delivered** (ADR-0008, ADR-0062). The
  sidebar line says `✅ finished`, `whiska inbox` lists it apart from what waits, and the
  owl reminds the person while its branch has work to land.
- **`needs-decision` → delivered.** Valid, and redundant, since absence says the same.

A marker is required to be quiet, not to be heard. A model cannot be relied on to emit an
exact marker every time, so the question is which way that failure breaks: under a scheme
where absence meant nothing, a forgotten marker meant a mouse sat waiting and nobody was
told. Forgetting is now the safe direction, as push detection is designed to err broad
(ADR-0011).

## The marker

**The marker is a last line of U+2063 (INVISIBLE SEPARATOR) and nothing else: three for
`done`, two for `needs-decision`.** A `needs-decision` pointer sits on the readable line
above it, as content the person reads in the pane. Only the last marker line counts, for
classification, for the pointer and for the strip; every other line is left as written,
so a mouse quoting the grammar mid-sentence is not blanked.

A readable line printed in the mouse's pane on every turn, noise the person reads past
forever. Every readable way of hiding one was tried in a throwaway pane with a `Stop` hook
logging the payload: an HTML comment, a link reference definition, the `[//]: #` trick,
`<span hidden>`, a footnote definition and `<details>`. All six printed verbatim; the
renderer passes HTML and reference lines through as text. The only thing that does not
print is a line made of characters that draw nothing.

The cost: the marker is unreadable to a person debugging it, and a model reproducing
exact invisible codepoints is less dependable than one typing a word. A garbled marker
arrives unmarked and is delivered loudly, never swallowed, and the count of unmarked
arrivals is the evidence for whether the marker is worth keeping. The older bracket
spelling, `[worktree-status: done]`, is still read and never written. Text a mouse merely
quotes could end in two or three separators; no guard is added, since guessing which lines
a mouse meant is the heuristic this record refuses, and the worst case is a turn closed as
finished rather than lost. `WHISKA_DEBUG=1` renders the marker visibly and logs what the
hook read.

## `done` means the task is done

A turn that stops short of its task on purpose, a failing test written first or an answer
to a question asked mid-task, ends on `needs-decision`, its question naming the concrete
next step. Seen live: a mouse told to write a failing test first did, stopped
with it uncommitted, ended on `done`, and the finish options recommended landing a branch
whose test would have broken CI. The two markers and the owl's reading of them do not
move; their meaning sharpens.

`whiska show` prints a branch line for a finished question, read from git and
never from the message: commits beyond the base, files not committed, or `unknown`. The
person says land, pr or drop, and `whiska land` and `whiska pr` refuse files not committed
and name them, so the person sees each before it is offered a commit: measured across this
machine's mice, 29 of 126 finished turns that changed files ended with changes not
committed, because nothing asked a mouse to commit, so `done` beside uncommitted files is
far more often finished work nobody committed than a mouse that stopped short. On the
person's ok, `--commit <file>` commits them in the mouse's worktree with a message the
main session wrote to that file (ADR-0088). The cost: a mouse that
stopped short and still ended on `done` has its half-done work committed and landed; the
marker rule is the only guard there.

## What the line carries

The delivered line is `🐱 <branch> <verb> · #<id> · "<pointer>" · <n> more open` and
carries no command: a line that reads like code gets acted on. The main session knows it
from its brief and runs `whiska show` (ADR-0088). The id stays
because answers are keyed to it (ADR-0005).

A turn with a background subagent still out is not a stop: the hook writes nothing
(ADR-0052). Everything the hook cannot read counts as ended, so that rule fails in the
same direction as this one.

## Considered options

- **Deliver an unmarked stop as a non-blocking notice.** Rejected: a notice says something
  is wrong and leaves the person to find the mouse; a question gives a reply channel
  straight into its pane, which is what a mouse that stopped for an unstated reason needs.
  It also keeps one code path rather than two delivery kinds.
- **Deliver `done` as a finished line.** The decision until 2026-10-14. Rejected: a report
  that needs no answer took the one delivery slot ahead of real questions (ADR-0008). It
  had replaced recording `done` without delivering it, under which a finished mouse
  vanished, its report readable only by someone who already knew to run
  `whiska questions <id>`. The sidebar's `✅ finished` line, the inbox's finished block and
  the reminder (ADR-0062) are what keep it from vanishing now.
- **A third marker for "stopped short".** Rejected: it changes the parser, the line, the
  hoot and the sidebar, and still needs a way to say "carry on".
- **Recording the branch in the `Stop` hook.** Rejected: landing needs the branch as it
  is when the person says so, not as it was when the turn ended.

## Consequences

- An unmarked question occupies the delivery slot like any other, which is the gate
  serialising as designed: a mouse that stopped without explaining itself is more likely
  to need attention than one that asked politely.
- A `done` report is a question in storage, closed from the moment it is recorded: it
  supersedes its mouse's earlier questions and is never in the queue.
- Recording that an entry arrived unmarked is deliberate evidence of which mice forget and
  how often.

Changed on 2026-10-13: a finished branch is landed, opened as a merge request or dropped by
`whiska land`, `whiska pr` or `whiska drop` on the person's word, with no options offered
(ADR-0088).

Changed on 2026-10-14: `done` is recorded closed and hooted, never delivered (ADR-0008,
ADR-0062).
