# The repo-scoped statusline is a board, and the owl writes it to a file

**Supersedes the repo-scoped half of
[ADR-0027](0027-statusline-detail-for-one-count-for-many.md)** — its mice segment and its
"a count for many" rule for Claude Code's statusline — and **amends
[ADR-0044](0044-the-statusline-redraws-on-a-timer-not-a-typed-nudge.md)**'s interval and
the arithmetic behind it. ADR-0027 still governs herdr's tab bar, unchanged.

A person with several mice running has no way to see what they are doing without asking
each one. `whiska mice` answers when asked, and being asked is the problem: the question
comes up while the person is in the middle of something else, in a session whose scrollback
is about something else.

ADR-0027 ruled a row per mouse out on a premise that turns out to be false:

> One terminal line has room for one real phrase. So the statusline names the single case
> and falls back to a count beyond it […] two or more fall back to `🐭×3 · 🐱 2 open`,
> with `whiska mice` as the place to see one excerpt per mouse without a width fight.

Claude Code renders a statusline of as many lines as the script prints. There was never a
width fight to avoid.

## Decision

**This repo's Claude Code statusline is a board**: one row per mouse — branch, herdr's
status, and one column of detail, which is the question waiting on the person if there is
one and otherwise what the mouse is doing (ADR-0050). Five rows at most, ordered waiting,
blocked, working, quiet; the rest become `🐭 +3 more`. **The cap never drops a mouse that
is waiting on the person** — a board that can hide a question is worse than no board.

**A dead mouse (ADR-0026) keeps a row only while it still has an orphaned question**,
dimmed, under the live rows, carrying the `whiska close <id>` that clears it. That
question is the one thing left that the person can act on; a dead mouse with nothing
waiting drops off. **The board never acts.** It shows the command; the person runs it.

**The owl writes the board, every two seconds, to `~/.whiska/board/<main checkout>`**, and
the statusline script prints that file. This is the load-bearing part. ADR-0044 set the
interval at 15 seconds because one run of the script cost ~0.8 core-seconds, nearly all of
it escript startup, which at 2 seconds would be ~40% of a core per idle session, forever.
The script now starts nothing: your global statusline, then `cat`. The cost moves to the
owl, which is one process for the machine and already has every house open.

**`whiska init` writes `refreshInterval: 2`.**

**A mouse's own session draws no board.** `.claude/settings.json` is committed, so every
worktree runs the same script; a mouse has no use for its siblings' rows and would spend
five rows of its own pane on them. The script skips any directory under `worktrees/`.

**A board nobody has refreshed says so.** Up to 5 seconds old it is drawn as it is; up to
a minute it is drawn dimmed under `🦉 owl down · 40s stale`; past a minute it is not drawn
at all. Rows that are 40 seconds old are still mostly true, and hiding them at the moment
something is wrong is the worse failure.

**`whiska watch` prints the board once and exits** — the same renderer, worked out now
rather than read from the file. It is what the person runs when the statusline looks
wrong. `whiska statusline --here` is the same board, kept as the name `whiska init`
already wired up and as the quiet one: outside a checkout it prints nothing and exits 0,
because it runs wherever a session is sitting.

**No slash-command skill**, against ADR-0022's letter. That rule exists so the main
session never composes bash for a command it runs on the person's behalf; the board is not
run on anyone's behalf — it is drawn, or typed by the person into their own terminal.

## Consequences

- **The repo-scoped renderer is gone from `Whiska.Statusline`**, which is now the tab bar
  and nothing else. There is one renderer for one line, so the file and the command cannot
  disagree about what the board says.
- **Doorstep entries no longer appear on this line.** The old one counted them, so an
  uncollected entry showed even with the owl down. The board is the owl's own output: with
  the owl down it goes stale and, after a minute, blank. What is lost is small — an entry
  is collected within seconds of a mouse finishing while the owl runs — and herdr's tab
  bar still carries `🦉 owl down`, machine-wide, drawn by herdr's server rather than by
  the owl (ADR-0048).
- **Each house asks herdr for its panes every two seconds.** One local socket round-trip
  per open house, which is what ADR-0025's addendum already prices for a refresh, now on a
  timer the owl owns rather than in every session.
- **A repo `init`-ed before today keeps the old script and the old 15.** Nothing breaks:
  the old script runs `whiska statusline --here`, which now prints the board, at a
  fifteen-second refresh. `whiska init` replaces the whole entry and the script.
- **The board file is machine-readable by nothing.** It is rendered text, named after the
  main checkout so that bash can find it with `tr -c 'A-Za-z0-9' '-'` and no escript. A
  session in a subfolder walks up until it finds one.

## Considered options

**Keep the board in a pane of its own** — `whiska watch --follow`, a long-running process
in a herdr pane. Rejected by the person whose screen it is: a pane has to be opened,
placed and remembered, and the statusline is already in front of them. The renderer is the
same either way, so `--follow` stays an afternoon's work if the pane is ever wanted.

**Board rows in the statusline, computed per session at 2 seconds.** The obvious version,
and the one that costs ~40% of a core per open session. Rejected on ADR-0044's arithmetic,
re-measured and unchanged.

**Board rows at the old 15 seconds, no owl involved.** Free, and answers a different
question: "what were these mice doing a quarter of a minute ago". The board's whole claim
is that it is current.

**An interactive board** — keys to close a question, drop a worktree, jump to a pane.
Rejected for now: it needs a key-handling terminal loop, it cannot live in a statusline at
all, and a board that can destroy a worktree on one keystroke is a different thing to
build than a board that reports. Nothing here forecloses it.
