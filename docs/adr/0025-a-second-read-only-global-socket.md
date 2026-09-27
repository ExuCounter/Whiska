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

## Addendum (2026-09-27): until the socket exists, the statusline goes around it

The global socket is designed and not built. The statusline's "elsewhere" segment
(ADR-0027) does not wait for it: it finds every whiska on the machine through herdr's
own machine-wide pane list — an agent pane in a repo root that has a house — and reads
each such house's database directly, the way `whiska questions` reads this repo's.
That is one `pane.list` call plus a read-only open per other house, on every refresh.

Why this does not undo the decision: everything the segment needs is either a live
pane, which herdr already knows about, or a house on disk, which is readable without
the owl. It also keeps the segment working when the owl is down, which the socket
never could. The limit is honest: a repo with no live whiska pane is invisible to the
count, and nobody is there to answer anyway. When the socket lands, the statusline
switches to it in one place (`Whiska.Statusline.summary/2`) and the direct reads go.
`whiska projects` and `whiska goto` still wait for the socket.
