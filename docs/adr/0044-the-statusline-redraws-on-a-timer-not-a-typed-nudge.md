# The statusline redraws on a timer, not a typed nudge

**Amended 2026-09-29 by
[ADR-0051](0051-the-repo-scoped-statusline-is-a-board-the-owl-writes.md)**: the interval
is 2 seconds, not 15. The arithmetic below is unchanged and is the reason — it prices
escript startup in every session, and the statusline script no longer starts anything.
The owl renders the repo-scoped line into a file and the script prints it.


**Partly superseded 2026-09-29 by
[ADR-0048](0048-the-owls-line-is-drawn-on-herdrs-tab-bar.md)**, and partly
restored by its amendment of the same day.

The **elsewhere** segment, which this ADR's timer was written for, is gone: the
machine-wide line left Claude Code for herdr's tab bar, where one pull every
five seconds serves every repo at once. The **`refreshInterval: 15`** is back,
beside the repo-scoped statusLine that came back with it, and its arithmetic
below is what still sets the number. What it keeps current is different: a mouse
spawning or dying, and a second question in a house whose delivery slot is
already held — neither of which types anything into the session.

**Amended 2026-10-03 by
[ADR-0067](0067-a-turn-that-died-is-picked-up.md)**, which gives the rule below its one
exception.

What this ADR decided about the *nudge* otherwise still holds: nothing in Whiska types
into a session that is not its own house's main session, **except a mouse's own pane,
when that mouse's own turn died, once**. The reasoning below is about a line typed into
*another house's* session, about work that session had nothing to do with, where the turn
it cost was pure waste. ADR-0067 is the opposite case — the stalled mouse's own
unfinished work — and the turn is the point of it. The rejection of "gate it and
rate-limit it" further down stands for a redraw, which needs no turn at all, and does not
reach resuming work, which cannot happen without one.

**Amended 2026-10-06 by
[ADR-0080](0080-an-answer-is-taken-not-typed.md)**, which
gives the rule a second exception: **a mouse's own pane, while an answer the person gave it
is not taken, at most three times.** The owl rings the doorbell again — one fixed line
with the question id — only into an idle pane with an empty prompt box, never into a held
mouse or the main session. The same reasoning as ADR-0067's holds: the line is about that
mouse's own answer, and the turn it costs is the answer arriving. No other exception is
added.

**Supersedes [ADR-0041](0041-a-nudge-is-a-notice-typed-into-another-houses-main-session.md)**,
which had the owl type `⚡ <folders> waiting` into every other open house's idle main
session.

The problem ADR-0041 set out to solve is real and unchanged: the statusline's elsewhere
segment (ADR-0027) names the other project with something waiting, and Claude Code's
event triggers for redrawing the statusline all come from the session's own conversation.
A person sitting idle in one repo sees a snapshot from their last keystroke, so a question
opening in another repo changes nothing on their screen until they type — which is exactly
the moment the segment stops mattering.

ADR-0041's answer was to manufacture the missing conversation change. That is what went
wrong. A nudge lands in the target session as a **user turn**, and Claude Code cannot tell
one from a prompt the person typed. So each nudge costs that session a turn, and the model
improvises a response to it: in one dotfiles session, three separate nudges each provoked a
`whiska questions` run *for the other repo* — work nobody asked for, in the wrong repo, at
the person's expense. ADR-0041 foresaw the shape of this ("the line lands as a user turn in
the target's Claude, which should have nothing to do with it beyond acknowledging") and
priced it at one brief acknowledgement. The price was higher.

There is also a sanctioned redraw path, which ADR-0041 did not have. Claude Code's
`statusLine` setting takes a `refreshInterval`, in seconds, minimum `1`, which re-runs the
statusline command on a timer *in addition to* the event triggers. It exists for this exact
case; the documentation names it ("when background subagents change git state while the
main session is idle").

## Decision

- **The nudge is gone.** Nothing in Whiska types into a session that is not its own
  house's main session. `Whiska.Owl.Nudge` is deleted, along with the house's report to it
  and `House.nudge/2`; the owl supervises a registry and its houses and nothing else.
  Delivery (ADR-0008) is once again the only thing Whiska types anywhere, and every line
  it types is about a mouse of that session's own repo.
- **`whiska init` writes `refreshInterval: 15` beside the statusLine command.** The
  elsewhere segment goes stale for at most 15 seconds while a session sits idle, and
  nothing has to be typed for it to come back.
- **The interval is 15 seconds, and here is the arithmetic.** One run of
  `.claude/hooks/whiska-statusline.sh` costs about 0.44 s of wall clock, nearly all of it
  escript startup. At 15 s that is a ~3% duty cycle per idle Claude Code session; with
  four sessions open on a laptop, ~12% of one core, permanently. At 10 s it would be ~4.4%
  each, buying five seconds of latency for half again the cost — not a trade worth making
  for a segment whose whole job is to be noticed when the person next looks up. Below
  about 5 s the runs would start overlapping badly with Claude Code's 300 ms debounce and
  its habit of cancelling an in-flight script when a new trigger arrives. If the escript
  startup cost is ever removed, the number is worth revisiting downwards.
- **An interval the person changed is theirs.** `whiska init` replaces its own statusLine
  entry wholesale, as it always has, so re-running `init` restores 15. But the doctor does
  not argue with a value the person set: any integer ≥ 1 reads as ok.
- **The doctor gains a `statusLine` check**, and it is a warning, never a failure. Nothing
  is lost when the statusline is wrong — questions are still collected, still recorded and
  still delivered — so it cannot be a `fail` under ADR-0038's reading of the three
  statuses. Three cases: no statusLine at all, ours with no `refreshInterval` (the drift
  this ADR creates, in every repo `init`-ed before today), and somebody else's script. Each
  points at `whiska init`.
- **No replacement for the instant case.** A person staring at repo A the second a
  question opens in repo B now waits up to 15 seconds instead of seeing it at once. That is
  accepted. The nudge was never instant either: it ran the target's delivery gate and was
  dropped, never retried, whenever that session was busy — which is most of the time a
  person is actually at their keyboard.

## Correction (2026-09-29): the duty cycle above is wall clock, not CPU

Re-measured when the interval came back: five runs of the whole script, prod escript,
real herdr socket, a real global statusline in front of it. 0.41 s of wall clock each,
and **0.81 core-seconds of CPU** each — the BEAM starts on more than one core, so wall
clock understates the cost by about half.

So every "~3% per idle session" below, and the "~12% of a core with four sessions" that
ADR-0048 built on it, is the wall-clock figure. The real numbers are **~5.4% of a core
per idle session** and ~22% with four open. The decision does not move: 15 s over 10 s
was the right call and is more clearly so at the corrected cost. The figure to quote is
5%, not 3%.

## Consequences

- Every repo `init`-ed before today has a statusLine with no `refreshInterval`. Nothing
  breaks; the elsewhere segment simply behaves as it did before ADR-0041. `whiska doctor`
  now says so, and `whiska init` fixes it.
- Cross-house coordination leaves the codebase entirely. `Whiska.OpenHouses` (ADR-0039) is
  still read — by the statusline's headcount and the doctor — but nothing acts across
  houses any more, so ADR-0041's "houses never call each other" stops being a rule anyone
  has to keep.
- ADR-0009's "one delivery kind, never a notice" has no exception again. ADR-0041 carved
  out exactly one, for the nudge, and it goes with it. ADR-0008's addendum about a nudge
  sharing the delivery slot is void for the same reason.
- `Whiska.Delivery.Text.nudge/1` is gone; `compose/4` is the only line Whiska writes.
- **ADR-0025's addendum costs a refresh differently now.** It prices the elsewhere
  segment at "one `pane.list` call plus a read-only open per other house, on every
  refresh" — written when a refresh only happened because the person typed. Under a timer
  that cost is periodic: an idle machine with three open houses does that work every 15
  seconds, forever. The decision does not change, and neither does the arithmetic above
  (the 0.44 s was measured on the whole script, elsewhere segment included), but the
  reason 15 s and not 1 s is now partly ADR-0025's: the houses are opened read-only and
  SQLite is happy with concurrent readers, yet there is no reason to do it sixty times a
  minute. When the global socket lands (ADR-0025) and the per-house opens go, the
  interval is worth revisiting downwards.
- `CONTEXT.md` retires **Nudge** rather than deleting it: the word was in commits, ADRs and
  two architecture diagrams, and a reader who meets it needs to be told it is not a thing
  any more.

## Considered options

**Keep the nudge but make the line invisible to the model** — a zero-width or whitespace
line, or one wrapped so Claude Code treats it as noise. Rejected: there is no such
wrapping. Anything typed into a pane is a user turn, and a turn the model is told to ignore
is still a turn billed, still a turn in the transcript, and still something the model may
decide to act on anyway.

**Send the nudge only to sessions with no work in flight, and rate-limit it.** Rejected: it
narrows the damage without removing it, and the person's objection was to the turn
existing, not to how often it happens.

**A redraw with no conversation turn, pushed from outside.** This is what was actually
wanted, and it does not exist. `SIGWINCH` to the `claude` process does not re-run the
statusline (tested); a bare keystroke through `herdr pane send-keys` does not either
(tested). `refreshInterval` is the only sanctioned path, and it is a pull, not a push.

**1 second, the minimum.** Rejected on the arithmetic above: a ~44% duty cycle per idle
session, for a segment nobody reads 60 times a minute.

**Drop the elsewhere segment too**, since it is the only thing that needs a redraw while
idle. Rejected by the brief, and rightly: the segment is how a person with several repos
open learns that one of them wants them. The timer makes it work; removing it would just
admit defeat.

## Amendment, 2026-10-07: no repo-scoped line is left to redraw

[ADR-0082](0082-a-mouses-state-is-a-line-in-herdrs-sidebar.md) removes the Claude Code statusline Whiska wrote, interval and all. herdr redraws the
tab bar on its own timer (ADR-0048), and the owl reports each mouse's sidebar line itself,
so no Claude Code session runs anything on a timer for Whiska.
