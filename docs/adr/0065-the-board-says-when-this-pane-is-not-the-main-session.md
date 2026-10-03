# The board says when this pane is not the main session

A house delivers into exactly one pane — the one `whiska start` recorded (ADR-0020) — and
every other Claude session in the same checkout looks identical from the inside. A person
sitting in the wrong one waits for answers that are being typed somewhere else, or are not
being typed at all because no main session was ever recorded. Reported twice from real use:
time lost waiting for a reply that was never coming.

The only way to find out was `whiska doctor`, which prints the recorded pane id. A pane id
is not something a person recognises on sight, so the answer to "is this session the
whiska?" was really "go and compare two strings".

## Decision

**The board carries it**, because the board is already the surface a person watches while
they wait: it is this repo's Claude Code statusline, redrawn every two seconds, and it is
where a question waiting on them appears (ADR-0051). A fact about whether answers reach
this session belongs next to the answers.

**Only the wrong case is said.** When this pane is the main session the board says nothing
new; when it is not, one line goes above the rows:

- recorded elsewhere — `🐱 not the main session — answers go to another pane; whiska start
  moves them here`
- nothing recorded at all — `🐱 no main session here — nothing is delivered until whiska
  start records this pane`

A permanent "you are the whiska" badge was the alternative, and it is the weaker signal for
the same reason it is the safer-sounding one: it is present in every session, in every
repo, on every redraw, so it becomes furniture, and a person who has stopped reading a line
that is always there will not notice the day it is absent. The line here is never there
when things are right, so its appearance is the event. It is also the board's own habit —
nothing waiting adds no segment (ADR-0027), a hold says so only once it has lasted
(ADR-0058).

**A mouse is never told it is missing a main session.** A mouse draws no board at all
(ADR-0051), and the notice rides the board, so it inherits that silence. The exclusion is
read from the session's *project* directory rather than its current one, because the
current one follows every `cd` the session runs (ADR-0053) — a mouse that steps into the
main checkout would otherwise be handed the main checkout's board and told it is not the
main session, which is true of a mouse and is not a problem a mouse can have.

That directory also decides *which* repo's board a session draws, and so this moves too:
a session now draws the board of the repo it started in rather than the repo it has
wandered into. That is the same reading of identity ADR-0053 settled for hooks, applied
to the one other place a session is asked what it speaks for.

**The owl writes the pane down beside the board**, at `~/.whiska/board/<slug>.main`, and
the statusline script compares it with `HERDR_PANE_ID` from its own environment. Two files
rather than a header line in the board: the script `cat`s the board exactly as the owl left
it, so nothing has to be parsed out of it first, and the board file stays precisely the
lines that get printed. The pane is re-read from the house on every board write rather than
taken from the house's cached copy, so a session that has just run `whiska start` stops
being warned on the next redraw rather than at the next backstop.

**`whiska doctor` names it too.** Its main-session line now says `w1:p2 (this pane)` or
`w1:p2 (not this pane)`, from the same `HERDR_PANE_ID`. Where the board interrupts, the
doctor answers when asked, and the two cannot disagree: both compare the recorded pane with
the pane they are running in.

## Consequences

**The notice can only appear where the board can, and only while it is fresh.** No house
open, no owl running, no board file — no line, in exactly the cases ADR-0051 already draws
nothing. Nor over a board more than ten seconds old: the recorded pane is written by the
same owl in the same breath as the board, so a board nobody is refreshing means the pane
beside it may have changed since. The case that forces this is a person running `whiska
start` while the owl is down — they would be told, in the pane they had just recorded,
that it is the wrong one. A repo nobody has run `whiska init` in has no statusline at all
and this is invisible there; that is the same gap the board itself has.

**It appears with no mice running.** The board file exists and is empty while a house is
quiet, and the notice is printed in its own right — the point is to be told before the
first question is asked, not after one has gone astray.

**A session outside herdr is told nothing.** With no `HERDR_PANE_ID` there is no pane to
compare, and "I cannot tell" must not read as "you are in the wrong place". Same reasoning
as ADR-0053's two signals: a missing signal is never evidence.

**The statusline script's version stamp goes to 3** (ADR-0059), so a copy an older `whiska
init` wrote is reported as upgradeable rather than silently lacking the line. A repo whose
committed script is v2 keeps its board and never shows the notice; nothing breaks, and the
sidecar it does not read costs one small file per house.

**`whiska watch` does not say it.** It prints the same rows on demand, in whatever pane the
person ran it from, and the question "am I the whiska" asked out loud is `whiska doctor`'s —
which now answers it in those words. Adding it in a third place would be a third thing to
keep in agreement.

## Alternatives

**Say it in the session itself, as a line Claude Code prints at startup.** It would be read
once, at the moment it is least relevant — the pane is usually recorded after the session
starts, by `! whiska start` from inside it — and it would be scrolled away by the time the
person is waiting.

**Have the owl refuse to write a board into a pane that is not the main session.** The board
is per house, not per pane: one file, read by every session in the checkout. Making it
per-reader would mean the owl writing a file per pane, and the board's whole cost argument
is that the script reads one file the owl already wrote.

**Name the recorded pane in the notice.** `answers go to w1:p2` is one more thing to read
and, by the complaint this ADR starts from, not a thing the person can act on. `whiska
doctor` prints the id for the case where it is genuinely wanted.
