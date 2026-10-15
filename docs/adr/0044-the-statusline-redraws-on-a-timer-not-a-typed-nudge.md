# Whiska types only into its own house's main session, and into a mouse's pane only about its own work

Delivery (ADR-0008) types into the main session of the question's own house, and into
it, a letter another repo's main session left there with `whiska tell`: one fixed line
naming that repo and the file's path in this house. Nothing in Whiska types into any other
session but a mouse, into its own pane, about its own work:

- a pickup of its dead turn, once (ADR-0067);
- the doorbell for an answer it has not taken, at most three times, only into an idle pane
  with an empty prompt box, never a held mouse's (ADR-0080);
- on `whiska spawn`, once Claude has started there, the task the person gave it, as its
  first prompt;
- on `whiska send`, one fixed line pointing at the file the person's words were copied to
  in the mouse's worktree;
- on `whiska resume`, its one fixed carry-on line (ADR-0080);
- on new review on its merge request, one fixed line pointing at a letter Whiska wrote in
  its worktree, only under the doorbell's bounds and only when nothing of it waits on the
  person (ADR-0060);
- when no mouse on that branch is live, the same line as the first prompt of a mouse the
  owl starts there, after `Your task:` (ADR-0060).

Spawn, send and tell run on the person's word, from the main session; a review round runs on
the forge's, and its letter holds links, ids and usernames cut to plain characters,
never a comment's or a log's text. A send types fixed text; a
spawn types the text of the file the main session wrote the person's task to, after a
fixed `Your task:` line, refused if it is not UTF-8 text or holds a control character but
tab or a line break (ADR-0088). Whiska types nothing a mouse or a forge wrote: a task
built from a finished investigation is fixed text naming its question, and comments
travel in a file. A letter's words travel in a file too, and the main session that reads
it shows them to the person and acts only on the person's word there. What the main
session writes into a task file is the person's to check. No other exception.

## Why

A line typed into a pane lands as a user turn, and Claude Code cannot tell it from a prompt
the person typed. The owl once typed `⚡ whiska waiting` into every other open house's idle
main session to force a statusline redraw. Each nudge cost that session a turn, and the
model improvised on it: in one session three nudges each provoked a `whiska questions` run
for the other repo, work nobody asked for, at the person's expense. The line was priced
at one brief acknowledgement; the price was higher.

There is no invisible line. A zero-width or whitespace line is still a turn billed, still
in the transcript, and still something the model may act on. `SIGWINCH` to the `claude`
process does not redraw a statusline and a bare keystroke does not either (tested); nothing
pushed from outside redraws a session without a turn.

The exceptions are the opposite case. The nudge spent a turn on work that session had
nothing to do with. A pickup spends the turn on the stalled mouse's own unfinished work,
which cannot resume without one; a doorbell's turn is the answer arriving; and a spawn or
a send is the person handing that mouse its task or their words, which it is there to act
on. A letter is the person's own words, which they asked one repo's main session to pass
to another's. A review round is the mouse's own merge request coming back to it: the work it was
there for, and nothing it pushes or posts to a person's thread goes without the person's
yes.

## Consequences

- Houses call each other only by a letter, on the person's word: `whiska tell` leaves it
  in the other house, and that house's own delivery types its line, under away and its
  gate (ADR-0008, ADR-0047). The owl supervises houses and nothing else, and acts across
  houses in no other way: what is waiting in another repo is the tab bar's to say
  (ADR-0048), pulled by herdr's server on a timer, and moving the person there is their own
  move (ADR-0043).
- ADR-0009's one delivery kind has no notice exception, and no notice shares the delivery
  slot. A finished report's line is a delivery that takes no slot: it is typed only once
  nothing waits (ADR-0008). A letter neither waits for the slot nor takes it.
- `Whiska.Delivery.Text.compose/4` is the line delivery writes for a question or a report,
  and `letter/2` the one for a letter. Another repo's CLI writes a letter's row, so the
  house types its line only for a plain file named as `whiska tell` names one, directly in
  its own letters folder, which is no link.

## Considered options

- **Make the nudge a real question in the target house.** Nobody there can answer it, and
  it would hold that house's slot until closed by hand.
- **Send it only to idle sessions, rate-limited.** Narrows the damage without removing it;
  the objection was to the turn existing.
- **Let the nudge hold the slot like a sent question.** Nothing closes a nudge, so it
  would need a timeout, which ADR-0008 rejects for sent questions.
- **A timer-driven statusline redraw in every session.** It replaced the nudge and is
  gone with the statusline (ADR-0048, ADR-0082).

Folded in on 2026-10-08: 0041 (its text is in git history).

Changed on 2026-10-13: `whiska spawn` and `whiska send` type one fixed line into a mouse's
pane, where the main session typed through herdr before (ADR-0088).

Changed on 2026-10-14: `whiska spawn` types the mouse's task as its first prompt, where it
typed a fixed line pointing at the brief (ADR-0088).

Changed on 2026-10-14: the owl types one fixed line into a mouse's pane about new review
on its merge request, and starts a mouse on that line when none is live (ADR-0060).

Changed on 2026-10-15: a main session leaves a letter in another open house with `whiska
tell`, on the person's word, and that house's delivery types one fixed line pointing at
it, where houses never called each other before. A main session told to pass something to
another repo's had no way to, short of guessing that session's name.
