# Whiska types only into its own house's main session, a pickup and a doorbell aside

Delivery (ADR-0008) types into the main session of the question's own house, and nothing
in Whiska types into any other session. Two exceptions, both into a mouse's own pane and
both about that mouse's own work: a pickup of its dead turn, once (ADR-0067), and the
doorbell for an answer it has not taken, at most three times, only into an idle pane with
an empty prompt box, never a held mouse's (ADR-0080). No other exception.

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

The two exceptions are the opposite case. The nudge spent a turn on work that session had
nothing to do with. A pickup spends the turn on the stalled mouse's own unfinished work,
which cannot resume without one, and a doorbell's turn is the answer arriving.

## Consequences

- Houses never call each other, and the owl supervises houses and nothing else. Nothing
  acts across houses: what is waiting in another repo is the tab bar's to say (ADR-0048),
  pulled by herdr's server on a timer, and moving the person there is their own move
  (ADR-0043).
- ADR-0009's one delivery kind has no notice exception, and no notice shares the delivery
  slot.
- `Whiska.Delivery.Text.compose/4` is the one line delivery writes.

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
