# Storage stays SQLite rather than reverting to flat files

Going back to flat files was reconsidered specifically to sidestep schema migrations.
Rejected: migrations in Elixir are a mature, well-worn feature (`Ecto.Migration`), not
something being pioneered here. Flat files would undo what this design deliberately moved
away from in the first place — real queries, no hand-rolled locking, no directory scanning.

## Consequences

Two simple tables replace what was previously a folder of files, a lock, and separate
tracking files. That is also what makes ADR-0005 possible: an answer points at a specific
question's id rather than "whatever is in this pane right now".
