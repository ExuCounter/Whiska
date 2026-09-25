# A house persists; start and stop only open and shut it

Earlier wording had `whiska stop` "tear down" a repo's house, but its SQLite database and
mouse records survive on disk and come back on the next `whiska start` — so that wording
left the surviving data belonging to nothing between runs. We decided a **house** is the
project's permanent home (its database, its mouse records, its identity), and that
starting and stopping only change whether it is **open** or **shut**: whether its socket
is listening, its sweep timer running, and its supervision live inside the owl.

## Considered options

The alternative was to treat a house as the running thing — `whiska stop` demolishes it,
`whiska start` builds a new one on the same plot. That matched the original wording, but
it forces a second term for the plot the data actually lives on, which buys nothing.

## Consequences

Nothing in the model is ever homeless. `whiska projects` lists *open* houses, and
`whiska doctor` checks whether this repo's house is open. Destroying a house is not a
thing any current command does; if one is ever needed, it is a new, separate operation
and should be named as such.
