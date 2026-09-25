# Mocking is confined to the herdr boundary

Standard current Elixir practice, not a shortcut: define a small formal behaviour for
"talking to herdr", with a real implementation for production and a `Mox` fake for tests.
That is the only place mocking is allowed.

## Consequences

Everything else — question routing, queueing, classification — is plain code tested for
real, with no mocking needed. herdr is the one genuine external boundary this system has,
because mice are herdr panes rather than processes Whiska owns (ADR-0020).
