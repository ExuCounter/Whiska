# One owl per machine, with a house per repo inside it

An earlier draft had `whiska start` spin up a fully separate OS process per repo. That
fought the grain of `launchd`/`brew services`, which is built to supervise one
long-running service cleanly rather than N processes appearing and disappearing as repos
are opened and closed, and it made both "stop just this repo" and "show what's waiting
on me across every project" awkward to build. We went instead with a single supervised
binary — the **owl** — in which every repo gets its own **house**: its own Unix socket,
its own SQLite connection, its own sweep timer, supervised independently inside the one
process.

## Consequences

Isolation is unchanged, and specifically security is not weakened. The property that
mattered was that a rogue process can't guess a shared port — it has to already be
inside a specific repo to find that repo's socket — and that comes from the socket
living under that repo's own `.git/`, not from being a separate OS process. One process
can listen on many private sockets at once.

Cross-repo visibility becomes cheap rather than a new subsystem: the owl already holds
every open house's state in one place, so "what's open anywhere" is one more query
against something that already knows the answer, instead of a new process talking to N
other processes over a new protocol.

## Note

`handoffs/handoff.md` records the superseded position ("one Whiska instance per repo, not
one shared daemon") as it stood at the time. It is a historical record and has not been
rewritten; this ADR is the current decision.
