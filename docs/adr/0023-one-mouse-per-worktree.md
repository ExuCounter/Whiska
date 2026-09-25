# One mouse per worktree, enforced rather than assumed

Two live panes reading the same marker file would fight over the same `mouse_id`: Whiska
could not tell which pane a reply should go to, and the "what is it doing" excerpt would
flip between two unrelated activities. Like everything else that must not break, this is
prevented mechanically rather than hoped for.

No new machinery was needed. Two things designed elsewhere solve it directly: the refusal
shape already designed for "two `whiska start` for the same repo" (refuse, and name the
pane that already holds it, with an explicit override), and the kernel-level peer-PID check
already designed against spoofing, which does the actual detection — a second unrelated
pane using the same worktree shows up as a genuinely different PID than the one on record
for that `mouse_id`.

## Consequences

The signal built for security turns out to be exactly the signal needed for this, so the
rule costs nothing extra to enforce.
