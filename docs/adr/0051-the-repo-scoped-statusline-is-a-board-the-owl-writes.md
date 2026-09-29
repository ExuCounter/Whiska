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
one and otherwise what the mouse is doing (ADR-0050). Five rows, ordered waiting, blocked,
working, quiet; the rest become `🐭 +3 more`. **The cap gives way to a question rather
than hide one** — five is a preference about height, and six mice all waiting get six
rows, because a board that can hide a question is worse than no board.

**A working mouse's row carries a ticker** — `·`, `··`, `···`, one frame per board the
owl writes, in a fixed column between the status and the detail so the detail never
shifts under it. The board's claim is that it is current, and on a row that says a mouse
is busy the person cannot tell a true still picture from a dead owl or a stuck timer. The
frame is counted in boards actually written rather than in wall-clock seconds, so it
moves exactly when the thing it vouches for happened. Only a working row ticks: an idle
mouse, a blocked one, one waiting on the person, a dead one and one herdr cannot account
for are all still, since a moving dot on those rows would say something is happening when
nothing is. A stale board is still for free — nobody is writing it, so the dots stop where
they were, under the `🦉 owl down` line that already says why. **`whiska watch` draws no
ticker and no column for one**: nothing is refreshing behind a board printed once, and a
dot that can never move says the opposite of what the ticker is for. The column is there
whenever a frame is — on the owl's board, working mouse or not — so the detail does not
jump sideways the moment the last working mouse stops.

**A dead mouse (ADR-0026) keeps a row only while it still has an orphaned question**,
dimmed, under the live rows, carrying the `whiska close <id>` that clears it. That
question is the one thing left that the person can act on; a dead mouse with nothing
waiting drops off. **The board never acts.** It shows the command; the person runs it.

**The owl writes the board, every two seconds, to `~/.whiska/board/<main checkout>`**, and
the statusline script prints that file. This is the load-bearing part. ADR-0044 set the
interval at 15 seconds because one run of the script cost ~0.8 core-seconds, nearly all of
it escript startup, which at 2 seconds would be ~40% of a core per idle session, forever.
Whiska's own part of the script starts nothing now — a `stat` and a `cat`, ~18 ms of CPU —
and the cost moves to the owl, which is one process for the machine and already has every
house open. One board tick measured at ~10 ms for a house with ten mice.

**The arithmetic, honestly, because the script is not free.** It still runs the person's
own global statusline first, and now does so 7.5 times as often. On the machine this was
built for that line costs ~49 ms of CPU, so the whole script is ~68 ms and the change is
34 ms/s against the old 54 ms/s — a win of about 1.6x, not the order of magnitude "starts
nothing" suggests. The break-even is a global statusline of about 90 ms of CPU: above
that — a `git status` in a big repo, a version probe, a token-usage lookup — two seconds
costs more than fifteen did, and the interval is the person's to lower. `whiska doctor`
does not argue with an interval they set (ADR-0044).

**`whiska init` writes `refreshInterval: 2`.**

**A mouse's own session draws no board.** `.claude/settings.json` is committed, so every
worktree runs the same script; a mouse has no use for its siblings' rows and would spend
five rows of its own pane on them. The script skips any directory under `worktrees/`, and
`whiska statusline --here` refuses there too — a repo still carrying the script an older
`whiska init` wrote would otherwise put the board in every mouse's pane.

**A board nobody has refreshed says so.** Up to 10 seconds old it is drawn as it is; up
to a minute it is drawn dimmed under `🦉 owl down · 40s stale`; past a minute it is not
drawn at all. Ten and not five because the house writes the board in the same process
that asks herdr for its panes, and herdr's client waits up to 7 seconds for a reply: a
slow herdr must not make a live owl announce itself dead. A row 40 seconds old is still
mostly true, and hiding it at the moment something is wrong is the worse failure.

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
- **Only the mice a row could be about are read.** Nothing is ever deleted (ADR-0007), so
  a year-old repo has a mouse record for every worktree it has ever had; reading them all
  thirty times a minute would be work that grows forever. The board reads the alive ones
  and the dead ones still holding a question.
- **Drawing the board can never stop a house.** It is wrapped: a reader that raises warns
  and leaves the board as it was, because collection and delivery must outlive anything
  that goes wrong in a picture. Without that, one malformed transcript field would
  crash-loop the house on its own two-second timer and take the owl's delivery with it.
- **A phrase on the board is stripped before it is written** — no control characters, one
  line, capped. The board file is the trust boundary: it is the first thing in Whiska that
  carries free text a mouse wrote into the person's terminal, and a terminal runs escape
  sequences rather than showing them. A newline would be worse than a strange row: it
  would forge a whole one, and a forged row can say that nothing is waiting.
- **The board file is machine-readable by nothing.** It is rendered text, named after the
  main checkout so that bash can find it with `LC_ALL=C tr -c 'A-Za-z0-9' '-'` and no
  escript — bytes, not characters, or a path with an accent in it would be spelled one way
  by the owl and another by the script. A session in a subfolder walks up until it finds
  one.

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
