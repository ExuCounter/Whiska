# Delivery is a queue, not a batch

Whiska delivers a question to the main session only when that session is idle *and* has
no other open, unanswered question already sitting there. Anything else joins the pile
silently. That single rule — not a timer, not a batching window — is what stops you being
pinged twice for things that land close together.

## Consequences

One narrow exception earns a timer: the very first question of a fresh round (main
session idle, nothing open) waits up to 8 seconds before delivering, so that if two or
three more land in that window, the first thing you see is an accurate count ("3 open")
instead of "1 open" with more trickling in behind it. Nothing is lost either way — the
window only affects what the first notification says, never what eventually arrives.

An earlier framing of this as "batching" was wrong and was corrected: it is a queue with
one narrow exception.

*Addendum, 2026-09-28, void since 2026-09-29.* This once carved out a nudge from another
house (ADR-0041): gated by this slot but never holding it. ADR-0044 deleted the nudge, so
the slot has one occupant again and no exception. A question of this house's own is the
only thing that is ever typed into its main session.

## When the idle signal is unavailable, deliver anyway

The gate depends on knowing whether the main session is idle. herdr reports this from a
real Claude Code hook rather than by reading the screen — `herdr-agent-state.sh`, bound to
`SessionStart` and `Stop` — and exposes `agent` and `agent_status` as separate fields. That
separation is what makes the failure case unambiguous:

| herdr reports | meaning | delivery |
|---|---|---|
| `claude` + `idle` | free | deliver |
| `claude` + `working` | mid-turn | hold — the normal case |
| `claude` + `unknown` | the integration is broken | **deliver anyway, and say so** |
| no agent | the main session's pane is not running Claude | a dead pane, not a busy one |

Holding on `unknown` was rejected. If the integration is broken there is no idle signal to
gate on, so holding is not caution — it is choosing silence, and the person would never
learn why the mice went quiet. Delivering interrupts at a slightly rude moment and carries
its own explanation, which is self-diagnosing.

A startup check in `whiska start` was considered and rejected as well. It fires once, so it
catches the least likely moment (a machine that was already broken) and misses the likely
one (herdr updated mid-session, leaving the hook stale). Keying on `claude` + `unknown`
detects the real fault at the moment it matters, with no new machinery.

## Note, 2026-10-01: a finished line is not in the queue at all

*Superseded by the note of 2026-10-06 below: a finished line now waits for the slot. What
this note says about the gates, the orphan cascade and the id outliving the closing still
stands.*

The slot above is a rule about *questions* — one thing out at a time, because the person
can only be answering one. A `done` report is not one. Nothing is waiting on the person
in it; it is told, and that is the end of it. Queueing it behind an unanswered question
therefore bought nothing and cost the thing the report exists for: a branch that was
finished looked silent until the person happened to answer something unrelated, which
could be hours.

**So a finished line never waits for the slot and never holds it.** It is typed as soon as
the main session is idle and the box is empty (ADR-0047), ahead of whatever is queued, and
it is recorded delivered and closed on the spot rather than left `sent`. Decisions and
unmarked stops are untouched: one at a time, exactly as above.

Two parts of the gate still apply to it, and deliberately.

**The idle gate and the draft gate.** A finished line is still typed into the person's
prompt box, so everything about *when* it is safe to type there is unchanged.

**The first-of-round wait, where there is one.** The 8 s window opens on a collection that
finds the house quiet — nothing open, nothing out — and a finished line that starts such a
round waits it out like anything else, because it carries the same count. A finished line
that lands while something is already out starts no round and waits for nothing: the only
thing it could be waiting on is the question it must not wait on. Two mice finishing
seconds apart in that state are therefore two separate lines rather than one carrying a
count, which is the price of the branch being heard about at all.

**Not changed here: a finished report can still be orphaned and never told.** A mouse whose
pane closes, or whose worktree is dropped, has everything it left waiting cascaded to
`orphaned` (ADR-0026, ADR-0036) — a report included, although a report needs no answer and
could still be told. That is the same silence this note removes, reached a different way,
and it is ADR-0036's recorded decision rather than a slip. Left as it stands.

The id outlives the closing. `whiska questions <id>` reads a question by id with no regard
for its status, so the `whiska-delivered` picker (ADR-0022) still reads the message it was
told about and still offers the finish. This was already true — a `done` report has been
closed on sending since ADR-0009's revision — and is now covered by a test.

What does change in `whiska questions`: a finished report is `open` for a shorter time and
`closed` sooner, so it leaves the waiting list the moment it is told rather than when the
queue in front of it clears.

## Note, 2026-10-06: a finished line waits for the slot, and still never holds it

The note of 2026-10-01 priced waiting at nothing, because a report needs no answer. Typing
one is not free, though. The line makes the main session take a turn, and that turn prints
the report and its land-or-PR picker over whatever the person was reading. Seen live: #192,
a spec waiting for the person's ok, was sent; while the person was still reading it, the
owl typed `🐱 feat/whiska-open finished · #193` and the picker landed on top of the spec.
The person asked not to be interrupted.

**So a finished line waits while any question is out.** It is typed at the next delivery
attempt after that question is answered, closed, superseded or orphaned. That is the end
of the turn when the person answers or dismisses from the main session. Otherwise it is
the next trigger, at worst the backstop's minute, the same as a queued question. Everything
else in the 2026-10-01 note still holds:

- **It never holds the slot.** It is closed as it is typed, so the next question does not
  wait for the person to act on the finish picker.
- **It goes first once the slot is free.** A finished report goes ahead of any question that
  is only queued, oldest report first.
- **The gates still apply.** It needs an idle main session and an empty prompt box (ADR-0047),
  and an open finish picker on screen keeps the next line out (ADR-0068).
- **Away, focus and hold judge it first** (ADR-0079). A sent question of a held mouse, or of
  one that is not focused, does not make a report wait.
- **Freeing the slot starts no round.** Only a collection that finds the house quiet opens
  the first-of-round wait.

**Several that piled up go one by one**, and each line counts the rest apart from other
questions: `🐱 feat-b finished · #2 · 1 more finished · 1 more open`. One line for all of
them was considered and rejected. It would change the line the `whiska-delivered` skill
reads, needing every installed copy reinstalled. It would also put several reports and
several finishes into one reply.

**There is no time limit.** A cap such as "go anyway after 30 minutes" was rejected: it
brings back the interruption this note removes.

**The cost, accepted knowingly.** While a decision sits unanswered, a finished branch gets no
line and no hoot (ADR-0062 raises the hoot with the line). That is the silence the 2026-10-01
note was written to remove, and it lasts as long as the decision does, hours if the person
leaves it. Two things keep it visible without interrupting. The board row reads `finished ·
queued behind #192`, and `inbox` and `whiska questions` say the same. `dismiss` frees the
slot.

**The orphan window grows with it.** The cascade at a mouse's death still orphans a report
it left waiting (ADR-0036, unchanged). Before, a report sat open for seconds; now it can sit
for as long as a decision does. If the finished mouse's pane closes in that time, the
report is never told: no line, no finish picker. It shows only on the board's orphaned line
and in `whiska questions`. Closing a finished branch's pane before its line arrives costs
the finish.

**One gap is left open.** After the person picks a finish — Land here, say — the next line
can arrive while they are still reading what the landing printed. Closing that gap would
mean a finished report holding the slot until its finish is acted on, which is a larger
decision than this one.
