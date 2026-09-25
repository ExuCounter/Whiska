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
