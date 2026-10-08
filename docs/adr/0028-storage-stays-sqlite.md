# Storage stays SQLite, and both the mouse and question tables persist

A house's records live in SQLite under the main checkout's `.git/`, through Ecto
migrations. Both tables carry their real schema from the first migration, so nothing
about them changed shape when the owl arrived; a hook opens the file per invocation when
the owl does not answer (ADR-0033), and an open house holds it open. Both tables persist: `Question` obviously must survive a restart, and `Mouse`
must too, because startup reconciliation checks whether each mouse's pane still exists,
which only works if its pane and path survived. Live activity, what a mouse is doing right
now, is memory-only: disposable state, not history.

## Considered options

**Flat files**, reconsidered to sidestep schema migrations. Rejected: migrations in Elixir
are a mature feature (`Ecto.Migration`), and flat files would undo what the design moved
away from in the first place: real queries, no hand-rolled locking, no directory scanning.

## Consequences

Two tables replace what was a folder of files, a lock and separate tracking files. That
is what makes ADR-0005 possible: an answer points at a specific question's id rather than
"whatever is in this pane right now".

Folded in on 2026-10-08: 0006 (its text is in git history).
