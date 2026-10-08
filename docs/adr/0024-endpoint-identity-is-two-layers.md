---
status: proposed
---

# Endpoint identity is two layers, with an honest limit

Designed, not built: the per-repo socket this hardens does not exist yet. Recorded so the
security argument is not redesigned from scratch.

A request to a repo's socket must not simply be believed.

1. **Cheap first pass:** a request presents the actual marker-file content, not merely an
   id, and Whiska cross-checks the claimed working directory against the path recorded
   when that id was created, rejecting a mismatch.
2. **Real backstop, kernel-level peer identity.** The endpoint is a Unix domain socket,
   so the listening side asks the kernel which process is on the other end
   (`LOCAL_PEERPID`, usable from Elixir/OTP, unfakeable by the connecting process) and
   walks that PID's real parent chain (`ps -o ppid=`) to confirm it descends from the
   legitimate `claude` process for that worktree.

## What it enforces

**One mouse per worktree.** Two live panes reading the same marker file would fight over
one `mouse_id`: Whiska could not tell which pane a reply goes to. The peer check is the
detector: a second unrelated pane using the same worktree shows up as a different PID
than the one on record for that `mouse_id`. The refusal shape is the one `whiska start`
uses for a second main session: refuse, name the pane that already holds it, offer an
explicit override.

**Taking over as main session is a handoff, not a theft.** With the override, the role
transfers and the old pane is told it has been released; silently demoting it would leave
a terminal that looks alive and receives nothing. Requiring `whiska stop` in the old pane
first was rejected as merely annoying: that pane is often on a machine the person walked
away from.

## The honest limit

Everything runs as the same OS user with no sandboxing, so this does not stop a
determined co-resident process; airtight protection would need OS-level isolation, which
is out of scope. It stops accidental and casual spoofing and anything short of a
deliberate attack.

A per-repo socket under that repo's own `.git/` is what makes it possible, and the
property survived the move to one shared owl (ADR-0001): a rogue process cannot guess a
shared port; it has to already be inside a specific repo to find that repo's socket. The
owl's two sockets in the home carry no peer check, for the reason ADR-0033 gives: a hook
request approves nothing, and the read-only socket cannot act.

Folded in on 2026-10-08: 0023 (its text is in git history).
