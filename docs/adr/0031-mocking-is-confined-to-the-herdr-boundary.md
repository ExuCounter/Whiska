# Mocking is confined to the herdr boundary

Standard current Elixir practice, not a shortcut: define a small formal behaviour for
"talking to herdr", with a real implementation for production and a `Mox` fake for tests.
That is the only place mocking is allowed.

## Consequences

Everything else — question routing, queueing, classification — is plain code tested for
real, with no mocking needed. herdr is the one genuine external boundary this system has,
because mice are herdr panes rather than processes Whiska owns (ADR-0020).

The behaviour covers both directions, not just outgoing calls. The owl **subscribes** to
herdr's socket API — `pane.agent_status_changed` gates delivery (ADR-0008) and
`pane_closed`/`pane_exited` detect dead mice (ADR-0026) — so an incoming event stream is
part of the same boundary and is faked the same way. Tests drive those events directly
instead of waiting on a real terminal, which is what makes event-driven collection
(ADR-0036) testable at all.
