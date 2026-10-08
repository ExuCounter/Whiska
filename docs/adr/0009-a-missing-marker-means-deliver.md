# A missing marker means deliver; `done` is delivered too, and never waits for an answer

When a mouse finishes a turn, Whiska classifies the message by the marker the mouse itself
wrote and by nothing else: no heuristics, no model reading the text. Judgment belongs to
the mouse and to the person, not to the router.

- **No marker → deliver.** The mouse stopped and did not say why; that is worth
  interrupting for. The question arrives like any other, carrying the whole final message,
  flagged as having arrived unmarked.
- **`done` → delivered**, told as "finished" with no reply offered, and closed once the
  person writes anything in the main session after it (ADR-0008).
- **`needs-decision` → delivered.** Valid, and redundant, since absence says the same.

A marker is required to be quiet, not to be heard. A model cannot be relied on to emit an
exact marker every time, so the question is which way that failure breaks: under a scheme
where absence meant nothing, a forgotten marker meant a mouse sat waiting and nobody was
told. Forgetting is now the safe direction, as push detection errs broad (ADR-0011) and
the shell allowlist refuses what it cannot read (ADR-0034).

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

## `done` means the brief is done

A turn that stops short of the brief on purpose, a failing test written first or an answer
to a question asked mid-task, ends on `needs-decision`, with its option A naming the
concrete next step. Seen live: a mouse told to write a failing test first did, stopped
with it uncommitted, ended on `done`, and the finish options recommended landing a branch
whose test would have broken CI. The two markers and the owl's reading of them do not
move; their meaning sharpens.

`whiska show` prints a branch line under a finished question's heading, read from git and
never from the message: commits beyond the base, files not committed, or `unknown`. The
finish options offer what fits (ADR-0022). Files not committed are offered a commit first:
measured across this machine's mice, 29 of 126 finished turns that changed files ended
with changes not committed, because nothing asked a mouse to commit, so `done` beside
uncommitted files is far more often finished work nobody committed than a mouse that
stopped short. The main session commits in the mouse's worktree with a message passed by
file (ADR-0074). The cost: a mouse that stopped short and still ended on `done` has its
half-done work committed and landed; the marker rule is the only guard there.

## What the line carries

The delivered line is `🐱 <branch> <verb> · #<id> · "<pointer>" · <n> more open` and
carries no command: a line that reads like code gets acted on. The `whiska-delivered`
skill recognises it and runs the read (ADR-0022). The id stays because answers are keyed
to it (ADR-0005).

A turn with a background subagent still out is not a stop: the hook writes nothing
(ADR-0052). Everything the hook cannot read counts as ended, so that rule fails in the
same direction as this one.

## Considered options

- **Deliver an unmarked stop as a non-blocking notice.** Rejected: a notice says something
  is wrong and leaves the person to find the mouse; a question gives a reply channel
  straight into its pane, which is what a mouse that stopped for an unstated reason needs.
  It also keeps one code path rather than two delivery kinds.
- **Record `done` and never deliver it.** Rejected after it ran: a finished mouse vanished,
  its report readable only by someone who already knew to run `whiska questions <id>`.
- **A third marker for "stopped short".** Rejected: it changes the parser, the line, the
  hoot and the sidebar, and still needs a way to say "carry on".
- **Recording the branch in the `Stop` hook.** Rejected: the options need the branch as it
  is when the person picks, not as it was when the turn ended.

## Consequences

- An unmarked question occupies the delivery slot like any other, which is the gate
  serialising as designed: a mouse that stopped without explaining itself is more likely
  to need attention than one that asked politely.
- A `done` report is a question in storage and in delivery, differing only in the verb and
  in what happens after it is sent.
- Recording that an entry arrived unmarked is deliberate evidence of which mice forget and
  how often.
