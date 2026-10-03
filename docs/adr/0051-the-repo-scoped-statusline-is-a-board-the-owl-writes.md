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

**A dead mouse (ADR-0026) has no row.** The board is what is running here, and a branch
whose worktree the person dropped is not. What it left behind is not lost: an orphaned
question is counted in the `🐱 n waiting` line and read in full with `whiska questions`
(the count moved to a line of its own — see the addendum of 2026-10-01).
**The board never acts** — it reports, and the person runs the command.

**The board and `whiska mice` read one set**, `Whiska.Storage.alive_mice/0`. Two readers
answering "what is running here" from two queries is a board that can disagree with the
command the person checks it against.

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
- **Every mouse record is read, and that is the tick's own cost.** Nothing is ever deleted
  (ADR-0007), so a year-old repo has a record for every worktree it has ever had — and
  which of them still stand for a worktree is a question about all of them together
  (see the note below), so the board cannot read only the ones it will draw. Measured on
  the machine this was built for: a house of 45 records costs 3.3 ms a tick, against the
  ~10 ms this decision budgets. The shape is one `readlink` per path segment per record
  and a pairwise comparison on top, so a house of 500 records would be 40 ms and over
  budget. When a repo gets there, canonicalising each distinct parent folder once is the
  cheap fix and takes almost all of it back.
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

## Note, 2026-10-01: dead rows are gone, and a stale record is not a mouse

Two rows the person did not want, both seen in one repo on one morning.

**The dimmed dead row is withdrawn.** It was there so an orphaned question kept the
`whiska close <id>` that settles it next to it. In use it reads as a branch still being
worked on, and the person has already dropped that worktree — the row is the one thing on
the board that is not about work in progress. A line underneath counts every orphan — the
`🐱 n waiting` one until the addendum of 2026-10-01 gave them `🐱 n orphaned` — and
`whiska questions` shows and settles them, so nothing is unreachable; the board is only
live mice now.

**A record whose folder holds another record's worktree is stale.** A branch with a slash
nests on disk, so `worktrees/feat/checkout-form` sits under `worktrees/feat` — an ordinary
folder that owns nothing (ADR-0030's note). The record made before that was understood
still points at the folder, so it holds every pane of the mouse inside it. Matching it
cleared its `died_at` (`Storage.set_pane/2`, which treats a pane in the worktree as proof
of life), and the pane map is keyed by pane, so the two records traded that one pane and
each in turn was marked dead for not having it. The board carried a branch that does not
exist, and flapped against `whiska mice`.

git will not carry a branch `feat` and a branch `feat/checkout-form` at once, so of two
records whose folders nest the deeper one stands — unless the shallower one was made
later, which is a branch taking back a name every nested branch has since left. Of two
records for the same folder, the newer one stands. The rule lives in
`Whiska.Storage.current_mice/0`, under the one set both readers use, and the owl matches
panes against it — a stale record takes no pane, and is marked dead on the same pass like
any other mouse with none.

## Addendum (2026-10-01): an orphan is counted, but not under the word "waiting"

This ADR, and the note above it, put orphans in the one count:

> an orphaned question is counted in the `🐱 n waiting` line

In use that line is a lie the person cannot act on. This repo's board said `🐱 1 waiting`
with one orphan behind it, `interview-template`'s said `🐱 2 waiting` with two, and
`whiska waiting` said nothing needs them — which was the true answer, since an orphan's
mouse and worktree are gone and there is nowhere to reply. A count that sends the person
to `whiska reply` for something no reply can reach is worse than no count.

**The board counts the two apart**: `🐱 n waiting`, every answerable question no row
carries, and under it `🐱 n orphaned`, everything a dead mouse left behind. Both lines are
drawn whenever their count is non-zero, so the rule above still holds in full — nothing
waiting leaves the board uncounted — and the person reads either in full with
`whiska questions`. `Whiska.Watch.board/2` splits the questions it is given by status, and
the two counts are never added.

## Addendum (2026-10-02): the detail column is the mouse's topic, and the action is the fallback

This ADR made the detail column two-way:

> one row per mouse — branch, herdr's status, and one column of detail, which is the
> question waiting on the person if there is one and otherwise what the mouse is doing
> (ADR-0050).

In use, "what the mouse is doing" is a raw tool call, and a raw tool call is machine
output: a row reading `Bash python3 - <<'PY'` says nothing about which piece of work the
mouse is on, which is the question the person opened the board with. The board had eight
rows of it and answered none of them.

**The column is three-way: the waiting question, else the mouse's topic, else its last
action.** The topic is herdr's `terminal_title_stripped` — the short human summary Claude
Code keeps of what a session is working on, `Order builder for distributors`,
`README for open source` — which herdr 0.8.2 already carries in the pane list the board
asks for anyway, so the topic costs no new call and no upgrade. `Whiska.Herdr`'s pane
shape, which dropped every field it had no use for, now keeps it.

**The action is what the person needs when the mouse is not getting on with it**, and the
board falls back to it in exactly two cases: a mouse herdr says is `blocked`, which is
sitting at a dialog, and a mouse herdr says is `working` that has written nothing to its
transcript for **two minutes**. Claude Code appends to that transcript every few seconds
while a turn runs, so two minutes of nothing is a genuinely long tool call or a stall —
and on a row that claims the mouse is busy, naming the thing it is stuck in is worth more
than naming the feature. The threshold is not shorter because an ordinary full test run
would then flip the column back to raw tool output for no reason, and the ticker already
proves the board itself is alive (that is a claim about the owl, this is a claim about
the mouse). Silence is read from the transcript file's own mtime, so it costs the stat
the board already does to find the newest session file.

**Silence counts only on a working row.** An idle mouse is silent by definition — it has
finished and is waiting to be told what is next — so its quiet says nothing about it
being stuck, and its topic stands however long it lasts.

**Nothing else moves.** A question waiting on the person still wins the column
(`whiska reply` is still the only thing the board is trying to get the person to do), and
a mouse with no title and nothing readable in its transcript still gets an empty column
rather than a guess. ADR-0050 is untouched: the action still comes from the mouse's own
transcript and is still never asked for. It is no longer the first thing the column says.

**The title is somebody else's string, and is treated as one.** It can be empty, it is
not a path, and in some panes it arrives with the agent's status glyph still on the
front, so the topic starts at the title's first letter or digit — a title with neither is
all glyph and is no topic at all — and `Whiska.Watch.Text` does the rest: one line, no
control characters, nothing invisible that reorders what is left, cut to the column's
width. The board file is still the trust boundary this ADR made it.

**Which row is a question is read from the question, not from the words in the column.**
The board used to find its waiting rows by matching the rendered detail against
`waiting on you`, which was safe only while no free text could reach that column first. A
topic can: a mouse whose title begins `waiting on you · #99` would otherwise have sorted
itself to the top of the board, taken the exemption from the five-row cap that this ADR
gives a real question, and pushed a real row into `+n more` — a forged question, pointing
at an id `whiska reply` cannot answer. The row already carries the question's id, and the
id is what the ordering and the cap read.

## Addendum (2026-10-02): a row says how long, and colour says which part to read

Two things the person could not get from a row: whether a mouse started a minute ago or
has been going since before lunch, and which part of a crowded row is the part for them.

**Every row carries how long its mouse has been going**, in its own column between the
status and the detail — `45s`, `6m`, `1h 33m`, `3d 4h`. It is `whiska mice`'s uptime,
spelled by `Whiska.Mice.format_uptime/1` itself rather than copied: the board and the
command answer the same question about the same records, and two spellings of `1h 33m`
would read as two answers. The column goes before the detail, which is the one column
whose width the board does not control, so the longest thing on the row stays last and
nothing it says pushes the elapsed time off the end.

**The redraw stays at two seconds.** An elapsed time is the obvious reason to want a
one-second statusline, and it is not worth one: the owl writes the board every two
seconds (`@default_board_ms`) and the statusline re-reads it every two
(`@statusline_refresh_interval`), so a one-second refresh prints the same file twice
unless the owl doubles its write rate for every house in every open session — the cost
this ADR picked two seconds to avoid. What the column shows moves in minutes.

**Plain ANSI colour, three codes, in `Whiska.Watch.Ink`**: the branch cyan, a question
waiting on the person yellow, the elapsed time dim. Those are the three things a row is
scanned for — which mouse, does it want me, how long — and everything else stays plain,
because a board where most things are coloured has nothing that stands out. The count
lines follow the same split: `🐱 n waiting` is yellow like the question it points at — and
the held clause of ADR-0058 rides that same line, so it is yellow with it — while
`🐱 n orphaned` and `🐭 +n more` are dim, since neither asks anything of the person.

**Plain codes, never a shade.** `36`, `33` and `2`, never a 256-colour or an RGB escape:
the shade belongs to the person's terminal theme, so a board drawn in a solarized
terminal is solarized, and stays right when they switch between its light and dark
variants. A hardcoded palette would be right in one terminal and wrong in every other.

**Colour never carries meaning on its own.** A waiting row still says "waiting on you ·
#52" in words, elapsed still reads `6m`, and the branch is still the first thing after
the `🐭`. Dropped colour changes nothing about what the board says — which is also what
keeps the board's tests reading it as plain text.

**The codes nest inside the dim a stale board is wrapped in.** The statusline script
wraps every line of a board older than ten seconds in `ESC[2m … ESC[0m`. A row that ended
its own colour with a full reset would end that wrapper half way along the line and leave
the rest of a board nobody is refreshing looking live, so a row ends colour with `39`
(default foreground) and dim with `22` (normal intensity), each turning off only itself.
`22` still ends the wrapper's dim as well — there is one dim attribute, not a stack — so
the script's `awk` puts a fresh `ESC[2m` after every `ESC[22m` it passes through. That is
the whole of the interaction, and it is checked by running the script over a coloured
board in `Whiska.InstallStatuslineBoardTest`.

**`whiska watch` is coloured too**, and keeps its codes when it is piped. The board is
one renderer (above), and splitting it into a coloured and an uncoloured one to detect a
terminal would be two renderers that can disagree — the thing this ADR set out not to
have. Piping the board somewhere is not something anything in Whiska does.

**A repo `init`-ed before today keeps the old script**, as this ADR's consequences already
say of the interval. Its board is coloured — the owl writes that — but its stale path dims
only as far as the row's first `ESC[22m`, so a board between ten seconds and a minute old
looks half live. Cosmetic, on the degraded path alone, and `whiska init` replaces the
script.

## Addendum (2026-10-03): the orphan line says which branches

The addendum of 2026-10-01 gave orphans a line of their own, and gave it only a number:

> under it `🐱 n orphaned`, everything a dead mouse left behind

A number alone is a nag. The person cannot tell whether the two orphans are a branch they
abandoned on purpose last week or the one they dropped this morning by mistake, so the
line asks to be looked into and gives nothing to look into it with.

**The line names them**: `🐱 2 orphaned (feat-checkout-form, fix-doctor-probe)`.

**The name is the branch, because the branch is what survives.** An orphan's mouse and
worktree are gone, but its mouse record is not — nothing is ever deleted (ADR-0007) — and
`branch` is a live label hanging off that record (ADR-0002), written when the mouse was
minted and never dependent on the worktree still standing. It is also the name
`whiska questions` already prints for the same question, so the board and the command
call one dead branch one thing.

**An orphan with no branch left is named by its own id** — `#52`. The record can have no
branch at all, and a question can reach the board without its mouse row; both are
genuinely nameless, and neither gets a guess. The id is not a name invented for the
occasion: it is the handle `whiska questions <id>` takes, which is the one thing the
person can do with an orphan. Its `mouse_id` is not used — an opaque marker id names
nothing to a reader and is wider than the branch column.

**Two orphans off one branch are one name with a count**, `feat-gone ×2`. The branch is
named once because the person recognises the work, not the question; the `×2` is there so
the names still add up to the count in front of them.

**More names than fit become `+n more`, and `n` counts questions.** The names take at most
60 characters — the detail column is the one the board lets run long, and this line sits
under it — and whatever is dropped is summed into the same `+n more` the board already
uses for rows it cannot show. Counting dropped questions rather than dropped names is
what keeps the line's arithmetic true: everything shown plus `+n more` is always the
count. One name is always shown even when it alone fills the budget; it is cut to the
same 24 characters as a row's branch.

**The count is unchanged and still comes from the records.** It is every orphaned
question in the house, counted before any name is dropped, so a narrow line never makes
the number smaller. Nothing reads it back off the rendered line.

**Nothing sorts or reads off rendered output**, as above. `Whiska.Watch.board/2` carries
the names on the board map alongside the count, worked out from the questions and their
mouse records; `render/2` decides only how many of them fit. A branch name is somebody
else's string like a topic is, so it goes through `Whiska.Watch.Text` before it reaches
the board file.
