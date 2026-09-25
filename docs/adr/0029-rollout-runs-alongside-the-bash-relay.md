# Whiska runs alongside the existing bash relay, with no hard cutover

Whiska controls real things — edits and pushes. Proving it out while today's bash
wake-queue system is still in place as a fallback is safer than switching all at once.

## Consequences

Both systems run together for a while. The old relay is not removed as part of shipping
Whiska; retiring it is a separate, later decision made once Whiska has actually earned it.
