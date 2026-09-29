# A mouse's last action is read from its Claude Code transcript, never asked for

The board (ADR-0051) shows what each mouse is doing. herdr answers half of that — `idle`,
`working`, `blocked` — and nothing in Whiska has ever answered the other half. ADR-0026
already leaned on the missing piece, calling it "the last-tool-call excerpt from knowing
what a mouse is doing", and ADR-0027's addendum recorded the same gap from the other side:
"the one-mouse excerpt is still unbuilt — nothing captures the last tool call yet".

Nothing captures it because nothing is in the room. The hook opens SQLite and exits
(ADR-0030, ADR-0033), so Whiska sees a mouse at the start of a tool call it might deny and
at the end of a turn, and never in between.

## Decision

**The excerpt is read from the mouse's own Claude Code transcript**, the JSONL Claude Code
writes as it goes to `~/.claude/projects/<worktree path>/<session>.jsonl`. The newest file
in that folder is the mouse's session; its last assistant message gives either the tool
call in flight (its name and what it is being done to) or the last sentence the mouse said.

**The folder name is the worktree's path with every character that is not a letter or a
digit replaced by a dash, one for one.** Checked against a real `~/.claude/projects` on
2026-09-29: `~/.herdr/worktrees/x` is recorded as `--herdr-worktrees-x`, the dot and the
slash each becoming their own dash, so nothing collapses.

**Only the tail is read** — 64 KB, with the first line dropped since it may have been cut
in half. A day's transcript runs to hundreds of KB and the board reads every mouse's every
two seconds.

**Nothing is ever asked of the mouse.** No prompt, no `herdr agent read`, no screen
scrape. This is the same rule ADR-0044 arrived at the hard way: anything typed into a
session is a user turn that costs it a turn and that the model will act on. A board that
interrupted eight mice every two seconds to ask what they were doing would be worse than
no board.

## Consequences

**The format is somebody else's, and can change under us.** That is the real cost of this
decision and the reason it is written down. Everything about the reader is therefore
defensive: a line that will not parse is skipped, a message with nothing recognisable in
it yields nothing, and "nothing" renders as an empty column rather than as an error. A
Claude Code release that renames a field costs the board its detail column and costs
Whiska nothing else — no collection, no delivery, no liveness judgment reads this file.

**The marker is stripped before a sentence becomes a row.** A mouse ends its turn on
invisible separators the person never sees; showing them on the board would be showing
them to the person by another route.

**It reads a file Whiska does not own, in the person's home.** Read-only, one folder,
derived from a worktree path Whiska already knows. Nothing is written there.

**The screen was the alternative and is worse.** `herdr pane read` returns a truncated
tail whatever `--lines` it is given, because Claude Code runs on the terminal's alternate
screen — the same fact that made a mouse leave its whole message on the doorstep rather
than have it read back (ADR-0036). A transcript is the thing the pane is a lossy rendering
of.

## Considered options

**Have the mouse report its own action.** A `PostToolUse` hook writing the last call into
the house. Rejected for now: it is a hook on every tool call in every mouse, paying the
native client's cost (ADR-0033) dozens of times a minute, to record something already
written to disk a millisecond earlier by Claude Code itself. Worth revisiting only if the
transcript format proves unstable — it is the version that does not depend on somebody
else's file.

**Show only what herdr knows.** Honest, free, and nearly useless: `working` for every
mouse that is working tells the person nothing they did not know from the mouse existing.
