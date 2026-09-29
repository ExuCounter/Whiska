# `whiska jump` moves the person's focus, and lands on the house's main session

Everything Whiska has asked herdr to do so far acts on a *mouse*: list panes, read one
pane, type into a pane (ADR-0020). Nothing has ever acted on the person. `whiska jump`
does — it asks herdr to bring a pane into view, and the person's screen moves.

The reason is a hotkey. `whiska waiting` now lists everything waiting across every house
in the open-houses record (ADR-0039), oldest first; the point of that list is to then go
to the top of it. Doing that by hand means reading the list, finding the right herdr
workspace and tab, and switching — every time, for something that is always the same
move. A Raycast script command bound to a global hotkey ("take me to whatever needs me")
collapses it to one keypress, and all it needs from Whiska is one line: focus that pane.

## Decision

- **Whiska may take the person's focus, but only when the person asked for it in that
  same breath.** `whiska jump` is typed, or fired from a hotkey the person bound. Nothing
  else in Whiska calls `focus` — not delivery, not the backstop, and above all not the
  owl. The owl has no cross-house move at all since ADR-0044 retired the nudge: it types
  into a house's own main session and nowhere else. An owl that could pull the screen
  around would be a different and much worse thing than one that can type a line.
- **It lands on the house's main session, not on a mouse's pane.** The waiting entry
  names a mouse, but the person does not work in a mouse's pane — they work in their own,
  the one `whiska start` recorded (CONTEXT.md, **Main session**). That is where the owl
  delivered the `🐱` line, where `whiska questions <id>` reads the full text, and where
  the answer is typed from. A mouse's pane is the mouse's workplace: landing there puts
  the person inside someone else's turn, mid-transcript, with nothing to type into that
  would not interrupt it. Jumping takes them to their own seat in the right project.
- **`whiska jump <repo|branch>` focuses that house's main session, waiting or not.**
  A bare word is read as a repo first, and as a branch — whichever house that mouse works
  in — when no repo is called that. Both resolve to the same destination, the house's main
  session, because "take me to the project I was working in" is the same move as the
  hotkey's, with the target named instead of inferred. Both are looked for across every
  recorded house, because neither name says which project it belongs to; a dead mouse's
  branch does not name a house (ADR-0026).
- **A house with no main session recorded is said out loud, and exits 0.** Nothing was
  ever recorded there, so `whiska start` in that repo's own pane is the fix, and the
  message says so. Exit 0 for the same reason nothing-waiting is exit 0: the hotkey is
  pressed on spec and the Raycast script must not report a failure.
- **`pane.focus` over the socket, with the pane id already stored.** herdr's socket API
  has `pane.focus {pane_id}` (checked against herdr 0.8.2's schema, protocol 20), and
  every house already records its main session's pane — `whiska start` writes it, and
  delivery types into it. So this is one more method on `Whiska.Herdr`, mocked at the
  same boundary as the rest (ADR-0031), and no new data.
- **Nothing waiting is a normal answer.** `whiska jump` with an empty list prints
  `nothing waiting` and exits 0. The hotkey is pressed on spec, and a non-zero exit would
  make a Raycast script report a failure for the case where everything is fine.

## Why this is not new ground, quite

`specs/spec.md` already describes `whiska goto <project>` — "asks herdr to focus that
project's main session pane directly, from wherever you currently are" — so focusing a
pane was designed for from the start and no recorded decision forbids it. What was never
written down is *which* pane and *who* may ask, and those are the two parts worth
recording: the main session rather than the mouse, and the person rather than the owl.
`whiska goto <project>` is now `whiska jump <repo>` under a different name and stays
unbuilt; there is no second command to write.

Checked and not in conflict: ADR-0020 (mice stay herdr panes — this uses the same
boundary for the same reason), ADR-0008 and ADR-0009 (delivery: untouched, jumping
neither delivers nor closes anything), ADR-0041 (the nudge, which was the owl's only
cross-house move and has since been retired by ADR-0044), ADR-0038 (the doctor never repairs — this is not the doctor),
ADR-0007 (nothing is deleted — this writes nothing at all).

## `whiska waiting` reads the record without the owl

`Whiska.OpenHouses.open/2` refuses to call a house open while no owl is in the process
table, and the statusline's headcount is right to use it (ADR-0039): a house nothing
collects cannot gain fresh questions. `whiska waiting` uses `read/1` instead and works
with the owl down.

That is not a contradiction. ADR-0039's own words for the record are that it "only says
which repos to look in", and nothing in the listing claims a house is open. A question
already in a house's database, or an entry already sitting on a doorstep, is waiting on
the person whether or not anything is awake — and a dead owl is exactly when the person
most needs to be told what piled up. The guard stays where it belongs: on the word
"open".

## Consequences

- `Whiska.Waiting` is the new shared reading, and `Whiska.Statusline`'s elsewhere segment
  now asks it rather than keeping its own copy, so `whiska waiting` and the statusline
  cannot disagree about what "waiting" means.
- `Whiska.Waiting` gains `house_for/2` (a name to a house) and `main_session/1` (a house
  to the pane a jump lands on). Every waiting entry still carries its *mouse's* pane —
  that is what `whiska waiting` prints and what `whiska reply` types into; it is simply
  not where a jump goes.
- `Whiska.Herdr` gains `focus/2`; `Whiska.Herdr.Socket` implements it as `pane.focus`.
  Every mock of the behaviour gains it too, which is the whole cost of the boundary.
- Neither command gets a slash-command skill. ADR-0022 splits the surface three ways and
  puts the machine-wide commands — its examples are `projects` and `goto` — outside the
  set a Claude session runs on the person's behalf. `jump` is the sharpest case of that:
  a session that ran it would yank the person's screen somewhere they did not ask to go.
- `CONTEXT.md` gains **Waiting** and **Jump**. Waiting had been used loosely for three
  different unions; it is now one state of a house — open and sent questions plus
  uncollected doorstep entries. (The Nudge entry it was contrasted with is retired:
  ADR-0044.)
- One bad house must not sink the listing. `whiska questions` may fail loudly for its own
  repo; a machine-wide read cannot, or one corrupt or locked database would hide every
  other repo's questions. `Whiska.Waiting` therefore catches a house that will not open
  *or* will not answer — `Storage.open/1` migrates as it opens, so a bad database raises
  from inside the open, after its connection is already up — shuts that connection down
  so the next house is not met with `{:already_started, _}`, says so once on stderr, and
  carries on. Silence there would read as that repo being quiet.
- The Raycast script is not shipped and nothing is written into anyone's dotfiles. The
  five lines it takes are in `whiska --help` under `jump`, to be copied by hand.

## Note, 2026-09-28: the target is the whiska, not the mouse

This ADR first decided the opposite — "it lands on the mouse's pane, not on the house's
main session" — and the decision above replaces it the day after it was built. The
rejected reasoning was that the mouse's pane holds the work, the diff and the transcript,
so that is where the context is. What it missed is that context is not what the hotkey is
for: the person presses it to *act* on something waiting, and every way of acting —
reading the full text, replying, closing — is run from their own main session. Landing in
a mouse's pane means arriving in the middle of another session's turn with nothing to do
there but read, and then switching again to answer.

What changes for the person: one keypress now lands in the project's own Claude Code
session, with the `🐱` line already delivered in it, rather than in a worktree's session.
`whiska jump <branch>` no longer focuses that branch's mouse; it focuses the main session
of the house that branch's mouse works in, and `whiska jump <repo>` does the same by repo
name. Nothing else moved: `whiska waiting` still prints each mouse's pane, and
`whiska reply` still types into it.

## Note, 2026-09-28: the hotkey runs without a shell environment

A Raycast script command bound to the hotkey runs `open -a kitty && whiska jump` with no
shell environment, so `HERDR_SOCKET_PATH` is unset there exactly as it is for launchd's
owl. ADR-0040's fallback to herdr's fixed default socket therefore applies to `jump` and
`reply` too, in one shared `Whiska.Herdr.socket/1`: the variable wins when set, herdr's
default is used when it is not, and only a default with no socket at it is refused —
naming the path, because by then the honest answer is that herdr is not running.
