# Endpoint identity is two layers, with an honest limit

A request to a repo's socket must not simply be believed.

1. **Cheap first pass:** a request must present the actual marker-file content, not merely
   claim an id, and Whiska cross-checks the claimed working directory against the path it
   recorded when that id was created, rejecting a mismatch.
2. **Real backstop — kernel-level peer identity, not the payload's word for it.** The
   endpoint is a Unix domain socket, not a network port. macOS lets the listening side ask
   the kernel exactly which real process is on the other end (`LOCAL_PEERPID`, confirmed
   usable from Elixir/OTP today), and that PID cannot be faked by the connecting process.
   Whiska walks that PID's real parent chain (`ps -o ppid=`) to confirm it is actually a
   descendant of the legitimate `claude` process for that worktree — not just something
   that read a marker file it happened to find.

## Consequences

Stated honestly rather than overclaimed: this does not stop a truly determined co-resident
process willing to go to real lengths. Everything runs as the same OS user with no
sandboxing, and airtight protection would need OS-level isolation, which is out of scope.
It stops accidental and casual spoofing and anything short of a deliberately sophisticated
attack — a real bar, not a token one.

Choosing a per-repo Unix socket under that repo's `.git/` is what makes this possible at
all, and it is also the property that survived the move to one shared process (ADR-0001):
a rogue process cannot guess a shared port, it has to already be inside a specific repo to
find that repo's socket.
