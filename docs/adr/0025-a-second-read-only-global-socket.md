# Cross-repo visibility uses a second, read-only global socket

A per-repo statusline only ever shows the repo you are sitting in, and with several
projects worked at once, something can be waiting on you in a different project's main
session. Answering "what is open anywhere" needs an endpoint that is not repo-scoped, so
there is a second socket at a fixed machine-level location (`~/.whiska/owl.sock`), distinct
from each repo's own private one.

## Consequences

The per-repo sockets stay exactly as hardened as designed — push approval, mouse identity,
the peer-PID check of ADR-0024. The global one is deliberately weaker, and that is safe
because it only ever answers read-only "what is open, where". It can never approve a push
or act on a mouse, so normal Unix file permissions — only your own user can read it — are
enough.

`whiska projects` and `whiska goto` talk to this socket, which is why they are the only
commands that work from anywhere on the machine rather than inside a repo.
