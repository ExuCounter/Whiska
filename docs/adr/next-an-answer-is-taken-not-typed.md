# An answer is taken by the mouse's own hook, not typed into its pane

**Amends [ADR-0044](0044-the-statusline-redraws-on-a-timer-not-a-typed-nudge.md)** (a
second exception to "nothing in Whiska types into a session that is not its own house's
main session") and **[ADR-0067](0067-a-turn-that-died-is-picked-up.md)** (where a turn
beginning is stamped, and one more mouse pickup leaves alone).

## The problem

`whiska reply` typed the person's whole answer into the mouse's pane through herdr, then
saved it. Three things went wrong with that:

- **Typed before saved.** When the save failed after the typing worked, the mouse had the
  answer while the question stayed `sent`, holding ADR-0008's one delivery slot over an
  answer that had already gone out.
- **Keystrokes are a bad carrier.** A multi-line answer went through the terminal, where
  a newline can submit half of it.
- **No proof.** A line the pane swallowed — a dialog up, a reconnecting herdr, a session
  mid-redraw — looked exactly like one that arrived. The person believed they had
  answered, and the mouse sat idle with nothing to show for it.

## Decision

**The answer is saved, then a doorbell is rung, then the mouse's own hook takes it.**

- `reply` saves the answer first. That is the whole of the person's part: the question is
  `answered` and ADR-0008's slot is free, exactly as before. Anything after the save
  failing is the owl's to retry, not a failed reply, so `reply` exits 0 and says so.
- Into the pane goes only the **doorbell**: one fixed line, carrying the question id.
- A **`UserPromptSubmit` hook** — Whiska's third, wired by `whiska init` beside
  `PreToolUse` and `Stop` — runs inside the session the line was submitted to. It reads
  the saved answer from the house database, gives it to the model as
  `additionalContext`, and stamps it **taken** (`taken_at`). Claude Code ran the hook in
  that session, so the stamp is the proof of delivery. The model does nothing.
- **Any prompt hands it over**, not only the doorbell: the person typing anything into the
  pane delivers an answer the owl gave up on, with no new command.
- **The owl rings again** while an answer is not taken: on the backstop, at least 90 s
  after the last ring, at most three times, only into an idle pane with an empty prompt
  box that herdr calls a worktree of this checkout, never into a held mouse and never into
  the main session. A busy pane waits and uses up no ring. 90 s after the third ring, the
  answer is marked **not taken** (`stale_at`), once: the board row, `inbox` and `whiska
  questions` say so, and one desktop notification goes out.
- **What is chased is derived, never stored**: answered, not taken, and the newest
  question its mouse has asked. A mouse that asked again has moved past the answer, so it
  is never handed over (ADR-0005's mismatch); death, landing and superseding need no new
  write path.

### The shell fast path

The hook fires on every prompt in every session on the machine, and almost none has an
answer waiting. An escript start costs ~140 ms, and ADR-0033's rule for a hook that fires
this often is that not running at all beats running fast. So the shim answers the common
case itself, in shell builtins: unless the session's
project directory is a worktree whose git admin directory holds a flag file,
`whiska-answer`, it exits 0 before the binary or the runtime is looked for.

The flag is a hint, never a record. `reply` raises it, the owl raises it again before a
ring, and the hook lowers it once nothing is chased. One left behind costs that one mouse
an escript start per prompt until its next prompt lowers it; one missing ends in the owl
ringing, then "not taken" and a notification. Neither loses an answer. It lives in the
worktree's git admin directory, so `git status` never shows it and removing the worktree
removes it.

## What this does to ADR-0044

ADR-0044's rule — nothing in Whiska types into a session that is not its own house's main
session — had one exception, ADR-0067's: a mouse's own pane, when that mouse's own turn
died, once. **It gains a second: a mouse's own pane, while an answer the person gave it is
not taken, at most three times.** ADR-0044's objection was a turn spent in a session about
work it had nothing to do with. Here the line is that mouse's own answer and the turn is
the point — ADR-0067's reasoning, for the same kind of line. A person watching the pane
sees the doorbell appear again with nobody typing.

## What this does to ADR-0067

ADR-0067 stamped a turn beginning from `whiska reply`, "because an answer typed into a
mouse is itself a prompt". A doorbell can be swallowed, so ringing one proves no turn
began; stamped at the ring, a swallowed doorbell would read as a died turn two minutes
later and get "your last turn ended on an error" typed into a mouse that never got its
answer. **The stamp moves to the take**, which is a turn beginning, in the session's own
hook. **Pickup leaves a mouse with a chased answer alone**: the doorbell is what carries
it on.

## Consequences

- Migration V011 adds `taken_at`, `rung_at`, `rings` and `stale_at` to the question. An
  answer given before it was typed whole into the pane, which was its delivery, so it is
  recorded as taken when it was sent.
- A repo that has not re-run `whiska init` has no prompt hook: its answers are rung, never
  taken, then marked not taken with the person told. `whiska doctor` fails the missing
  `UserPromptSubmit` entry and names the cost. The doorbell tells a mouse with no answer
  attached to say so and end the turn, so that gap reaches the person as a question too.
- `resume <branch>`'s carry-on line and pickup's line stay typed: both are Whiska's own
  fixed one-liners, not the person's words.
- The owl does not lower the flag itself: a sweep that read "nothing chased" just before
  `reply` saved an answer would lower the flag `reply` had just raised. The hook lowers it
  on the next prompt, which costs one escript start.

## Considered options

**The mouse acknowledges by moving a file to `handled/`** (firstmate's
`fm-task-inbox-lib.sh`). Rejected: the hook refuses it in every case. A sniff or unshaped
mouse is refused any shell command that changes a file (ADR-0018, ADR-0069), even a
`whiska ack`; a build mouse is refused a write under the house in the main checkout
(ADR-0013). Carving those out would weaken both rules for a step the model may still skip
— ADR-0010 puts what must happen in a hook, not in a line a mouse is asked to follow.
firstmate needs it because it drives agents with no hooks; Whiska only drives Claude Code
(ADR-0020).

**An answer file beside the hook.** A second copy of what the database already holds
durably, for a mouse that is handed the answer anyway.

**Hold the delivery slot until the answer is taken.** Every answer proven before the next
question arrives — and one swallowed doorbell stops every other mouse, the wedge
ADR-0057 removed.

**Keep typing the answer, and verify it from the transcript.** Still keystrokes for a
multi-line answer, and the check would depend on Claude Code's transcript wording
(ADR-0050) for something the hook states directly.
