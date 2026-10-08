# An answer is taken by the mouse's own hook, not typed into its pane

**The answer is saved, then a doorbell is rung, then the mouse's own hook takes it.** The
doorbell is the second exception to the rule that Whiska types only into its own house's
main session (ADR-0044), beside the pickup (ADR-0067): a mouse's own pane, while an answer
the person gave it is not taken, at most three times. The line is that mouse's own answer
and the turn is the point.

- `reply` saves the answer first. That is the whole of the person's part: the question is
  `answered` and the delivery slot is free (ADR-0008). Anything after the save failing is
  the owl's to retry, not a failed reply, so `reply` exits 0 and says so.
- Into the pane goes only the **doorbell**: one fixed line carrying the question id. It
  starts with 🔔, never the 🐱 of a delivered line: the `whiska-delivered` skill is listed
  in a mouse's session too, and fires on a 🐱 line with an id in it.
- A **`UserPromptSubmit` hook**, Whiska's third, runs inside the session the line was
  submitted to. It reads the saved answer from the house database, gives it to the model
  as `additionalContext`, and stamps it **taken** (`taken_at`). Claude Code ran the hook in
  that session, so the stamp is the proof of delivery. The model does nothing.
- **Any prompt hands it over**, not only the doorbell: the person typing anything into the
  pane delivers an answer the owl gave up on, with no new command.
- **The owl rings again** while an answer is not taken: on the backstop, at least 90 s
  after the last ring, at most three times, only into an idle pane with an empty prompt
  box that herdr calls a worktree of this checkout, never into a held mouse, a landed
  branch (ADR-0064) or the main session. A busy pane waits and uses up no ring. 90 s after
  the third ring the answer is marked **not taken** (`stale_at`), once: the sidebar line,
  `inbox` and `whiska questions` say so, and one desktop notification goes out. Telling
  the person waits behind what they set aside (ADR-0079): while they are away, or focused
  on another mouse, the ringing goes on and the giving up waits. A dead mouse's or a
  landed branch's answer is not listed as not taken, since nobody can act on it.
- **The take trusts nothing a mouse can forge alone.** The answers handed over are the
  ones of the mouse whose marker the worktree carries, and only while its record says it
  works in that worktree; a copied marker takes nothing (ADR-0005). The answer is read,
  then stamped in a second opening of the house, so a stamp that fails or is cut off
  still prints and leaves the flag up: an answer may arrive twice, never not at all.
- **What is chased is derived, never stored**: answered, not taken, and the newest
  question its mouse has asked. A mouse that asked again has moved past the answer, so it
  is never handed over; death, landing and superseding need no new write path.
- **A turn begins at the take.** The pickup's `worked_at` is stamped there, in the
  session's own hook (ADR-0067): a doorbell can be swallowed, so ringing one proves no
  turn began, and stamping at the ring would read a swallowed doorbell as a died turn two
  minutes later. Pickup leaves a mouse with a chased answer alone; the doorbell carries it
  on.

## The problem

`whiska reply` typed the whole answer into the mouse's pane, then saved it. When the save
failed after the typing worked, the mouse had the answer while the question stayed `sent`.
A multi-line answer went through the terminal, where a newline can submit half of it. And
a line the pane swallowed looked exactly like one that arrived, so the person believed
they had answered and the mouse sat idle.

## The shell fast path

The hook fires on every prompt in every session on the machine, and almost none has an
answer waiting. An escript start costs about 140 ms, and the rule for a hook that fires
this often is that not running at all beats running fast (ADR-0033). So the shim answers
the common case in shell builtins: unless the session's project directory is a worktree
whose git admin directory holds the flag file `whiska-answer`, it exits 0 before the
binary or the runtime is looked for.

The flag is a hint, never a record. `reply` raises it, the owl raises it again before a
ring, and the hook lowers it once nothing is chased. One left behind costs that mouse an
escript start per prompt until its next prompt lowers it; one missing ends in the owl
ringing, then "not taken" and a notification. Neither loses an answer. It lives in the
worktree's git admin directory, so `git status` never shows it and removing the worktree
removes it.

## Consequences

- The question carries `taken_at`, `rung_at`, `rings` and `stale_at`.
- A repo that has not re-run `whiska init` has no prompt hook: its answers are rung, never
  taken, then marked not taken with the person told. `whiska doctor` fails the missing
  `UserPromptSubmit` entry. The doorbell tells a mouse with no answer attached to say so
  and end the turn, so that gap reaches the person as a question too.
- `resume <branch>`'s carry-on line and pickup's line stay typed: both are Whiska's own
  fixed one-liners, not the person's words. The carry-on line answers the held mouse's
  stop, so it is stamped taken as it is saved; otherwise the owl would chase Whiska's own
  line as though the person had written it.
- The flag's place comes from the worktree's `.git` file, which the mouse there can
  rewrite, and the owl and `reply` act on it. So `.git` is read only when it is a plain
  file, since a named pipe would hang the owl, and the flag is created exclusively, never
  written through whatever a mouse left at its path (ADR-0013).
- The owl does not lower the flag itself: a sweep that read "nothing chased" just before
  `reply` saved an answer would lower the flag `reply` had just raised. The hook lowers it
  on the next prompt, which costs one escript start.

## Considered options

- **The mouse acknowledges by moving a file to `handled/`** (firstmate's way). Rejected:
  the hook refuses it in every case. A sniff or unshaped mouse is refused any shell command
  that changes a file (ADR-0069), even a `whiska ack`; a build mouse is refused a write
  under the house in the main checkout (ADR-0013). Carving those out would weaken both
  rules for a step the model may still skip; what must happen goes in a hook (ADR-0011).
  firstmate needs it because it drives agents with no hooks; Whiska only drives Claude
  Code (ADR-0020).
- **An answer file beside the hook.** A second copy of what the database already holds
  durably, for a mouse that is handed the answer anyway.
- **Hold the delivery slot until the answer is taken.** Every answer proven before the
  next question arrives, and one swallowed doorbell stops every other mouse, the wedge
  ADR-0008 removes.
- **Keep typing the answer, and verify it from the transcript.** Still keystrokes for a
  multi-line answer, and the check would depend on Claude Code's transcript wording
  (ADR-0050) for something the hook states directly.
