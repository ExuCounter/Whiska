# No `whiska spawn` command — spawning happens through a conversation

Proposed, then explicitly walked back. Spawning a mouse is a judgment call — which mode,
which model, is this even worth a worktree — and that belongs in a conversation with the
main session, not in a bare command with no thinking behind it.

## Consequences

Spawning stays something that happens *through* a conversation rather than being its own
command. `whiska history <branch>` is parked for a different reason: genuinely useful
occasionally ("why did I decide that, weeks ago"), but not core to the system working day
to day, so it gets built if it is actually missed rather than preemptively.
