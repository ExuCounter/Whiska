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

## Addendum (2026-09-27): what the built line says, and where the mice come from

The line as built, each segment following the same one-or-many rule, in this order:

```
🦉 owl down · 4 waiting · 🐭 2 mice · 🐱 2 questions waiting · ⚡ api-service waiting
```

- **Mice** are counted from herdr, not from the house: the worktrees of this repo with a
  live agent pane in them, one per worktree (ADR-0023). The house's `died_at` is only
  set while the owl runs, and the statusline is precisely the thing that must keep
  working when the owl is down. The one-mouse excerpt is still unbuilt — nothing
  captures the last tool call yet — so one mouse reads `🐭 1 mouse`.
- **Questions** say "questions waiting" rather than "open", so the number cannot be
  read as anything else. One question is still shown in detail.
- **Elsewhere** is the spec's `⚡` segment, and it is about *whiskas with something
  waiting*, not a headcount of sessions: one is named by its repo folder, several become
  `⚡ 3 whiskas waiting elsewhere`, none adds nothing. A whiska is a live agent pane in a
  repo root that has a house. How they are found is ADR-0025's addendum.

## Addendum (2026-09-27): the owl's state is always shown

Built as above, a quiet laptop rendered an empty line — and an empty line is exactly what
a broken Whiska renders too: a statusline script that cannot find the binary, a runtime
that is off PATH, a house that failed to open. Nothing on the line could tell "nothing is
waiting" from "nothing is working". So the owl's state is now always shown, and the
"nothing appended when nothing waits" rule is relaxed for this one segment only:

```
🦉 watching
🦉 watching · 🐈 3 whiskas
🦉 owl down · 4 waiting
```

- **`🦉 watching`** when the owl is up: in the process table (the doctor's probe,
  `Whiska.Owl.pids/0`, shared so the two cannot disagree) *and* collecting — a doorstep
  entry uncollected past the backstop still reads `🦉 owl down · N waiting`, whatever
  the process table says, because that is the signal delivery cannot give and the one
  this segment exists for. Down now shows immediately, with the count even when it is
  zero, rather than only once an entry has gone stale.
- **`🐈 N whiskas`** is a headcount of the whiskas on the machine — live agent panes in
  a repo root that has a house, found the way the elsewhere segment finds them (ADR-0025
  addendum) — shown only when there is more than one, the repo you are in always counted.
  It follows the one-or-many rule as before: one whiska is the quiet case and adds
  nothing; the owl segment says Whiska is alive.
- Every other segment keeps the rule: absent when it has nothing to say.

When the global socket lands, "up" becomes "the socket answers", in the same one place
the elsewhere segment switches over.

