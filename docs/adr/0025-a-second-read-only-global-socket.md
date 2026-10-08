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
(ADR-0048) does not wait for it: it finds every whiska on the machine through herdr's
own machine-wide pane list — an agent pane in a repo root that has a house — and reads
each such house's database directly, the way `whiska questions` reads this repo's.
That is one `pane.list` call plus a read-only open per other house, on every refresh.
(Since ADR-0044 a refresh also happens on a 15 s timer, not only when the person types,
so read that cost as periodic rather than keystroke-driven.)

Why this does not undo the decision: everything the segment needs is either a live
pane, which herdr already knows about, or a house on disk, which is readable without
the owl. It also keeps the segment working when the owl is down, which the socket
never could. The limit is honest: a repo with no live whiska pane is invisible to the
count, and nobody is there to answer anyway. When the socket lands, the statusline
switches to it in one place (`Whiska.Statusline.summary/2`) and the direct reads go.
`whiska projects` and `whiska goto` still wait for the socket.

## Addendum (2026-09-27): a whiska is an open house with a live pane

The definition above — an agent pane in a repo root that has a house — counted a repo
whose house was initialised once and never opened again, as long as a session sat in it.
ADR-0039 revises it: a whiska is a house in the owl's **open-houses record**
(`~/.whiska/houses`, in this same folder) with a live agent pane in its repo root. The
record is trusted only while an owl is in the process table, so with the owl down no
house is open and the elsewhere segment says nothing — the owl segment says what
matters then. The pane list is still herdr's and the other houses are still read
directly; only the set of repos looked at has changed. The switch to the socket, when it
lands, stays a one-place change.

**Note (2026-09-29, ADR-0048):** the elsewhere segment is gone — the statusline is one
machine-wide line drawn on herdr's tab bar — and with it the pane list this addendum
prices. What a refresh costs is now the per-house SQLite reads `Whiska.Waiting` already
does, five seconds apart, once for the machine rather than once per idle session. The
socket is still what replaces them.

## Addendum (2026-10-07): built, and joined by a hook socket

The socket exists. The owl listens on `~/.whiska/owl.sock` (or under `WHISKA_HOME`) from
the moment it starts, owner-only, and answers one plain-text request line with one line:

- `waiting` → `{"version":1,"waiting":[…]}`, the rows `whiska waiting --json` prints;
- `show <id> <main_checkout>` → one question with its whole text — the checkout is
  needed because question ids are numbered per house;
- `line [hint]` → the tab bar's line, plain text;
- anything else → `{"version":1,"error":"…"}`.

`version` changes only when a field does. The format is documented in the README,
because the person's own scripts — an fzf popup first — depend on it. It still only ever
reads: `show` answers only for a house in the open-houses record whose database is
already there, so asking about a path creates nothing.

`whiska projects` and `whiska goto` never shipped under those names; what they were for
is `whiska waiting` and `whiska jump`. Those, and `whiska statusline`, still read the
houses directly rather than asking the socket: they start Erlang either way, and reading
directly also works while the owl is down. The direct reads this record expected to go
therefore stay, for the command line; what moved onto the socket is herdr's tab bar
(ADR-0048).

**A second socket sits beside it, and it is not read-only.** Whiska's own hooks ask the
owl over `~/.whiska/hook.sock` (ADR-0033), and a hook writes: it records mice, mints
markers, leaves questions on the doorstep and stamps answers taken. Putting that on this
socket would have ended its one property, so it has its own, private and undocumented,
and this one stays read-only. The hook socket carries no ADR-0024 peer check, for the
reason ADR-0033 gives: it can do nothing the person's own account cannot already do by
running `whiska hook` with a made-up payload.
