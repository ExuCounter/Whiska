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
