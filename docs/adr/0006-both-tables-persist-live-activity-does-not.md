# Both Mouse and Question are persisted; live activity is memory-only

`Question` obviously needs to survive a restart. `Mouse` does too, and that is less
obvious: the startup sweep checks whether each mouse's pane still exists, which only
works if `pane` and `path` survive the restart in the first place. Without that, `reply`
and `diff` would silently break for every live mouse until something rediscovered them —
and nothing currently would. So both tables live in SQLite.

The "what is this mouse doing right now" excerpt is the deliberate exception. It is kept
in memory only (a GenServer/ETS value, not a row) because it is disposable state, not
history worth keeping. Losing it on a restart is fine in a way that losing a `Question`
is not.
