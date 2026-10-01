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
