# Statusline shows detail when there is exactly one thing, a count otherwise

One terminal line has room for one real phrase. So the statusline names the single case and
falls back to a count beyond it — applied twice, the same way both times. One mouse alive
shows its activity excerpt (`🐭 editing auth.ex`); two or more fall back to `🐭×3 · 🐱 2
open`, with `whiska mice` as the place to see one excerpt per mouse without a width fight.
One thing open in another project names that project (`⚡ api-service`); several fall back
to a count, since a bare number with no name attached is not something you can act on.

## Consequences

A project-level `statusLine` replaces the global one rather than merging with it, so the
script `whiska init` installs calls your existing global statusline first and appends to
its output. Nothing existing is lost.

Animation while mice work is a plain clock-driven frame pick (`🐭` → `🐭·` → `🐭··`), the
same idea as a terminal spinner — no push from Whiska and no hook into Claude Code's
internals, which firstmate does via an undocumented drawing API and which is not worth the
fragility. How smooth it looks depends on how often Claude Code calls the statusline
script, which is not confirmed.

## The statusline is also where "the owl is down" belongs

Delivery cannot report its own outage: if the owl is not answering, the channel that would
carry the message is the channel that is broken. The statusline is the only signal that
still works, because it runs in the main session's own process rather than the owl's.

It costs nothing extra. The script already has to ask the owl for its counts, so the
absence of an answer *is* the signal, and it falls back to reading the doorstep count off
disk — which works precisely because the doorstep is a directory of files and not a socket
(ADR-0036):

```
🦉 owl down · 4 waiting
```

This does not replace the doorstep, and the two must not be confused. The doorstep keeps
the message; the statusline tells the person. Each does only its own job.
