# `whiska jump` moves the person's focus, and lands on the mouse's pane

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
  owl. The owl's one cross-house move stays the nudge (ADR-0041), which types a line into
  an idle pane and leaves the screen where it is; that restraint was deliberate and is
  unchanged. An owl that could pull the screen around would be a different and much worse
  thing than one that can type a line.
- **It lands on the mouse's pane, not on the house's main session.** The waiting entry
  names a mouse, and the mouse's pane is where the work, the diff and the whole transcript
  are. The main session is where the *question* was delivered, which is a pointer to the
  mouse rather than the thing itself. `whiska reply <id> "..."` already answers from
  anywhere without moving at all (ADR-0005), so jumping is for the case where the person
  wants the context — and the context is the mouse's.
- **`whiska jump <branch>` focuses that branch's mouse whether or not it is waiting.**
  A branch names a mouse, not a question, and "take me to the one I was working in" is the
  same move with a different target. The branch is looked for across every recorded house,
  because a branch name says nothing about which project it belongs to. Dead mice are
  skipped (ADR-0026): their pane is gone, so focusing it would land nowhere.
- **`pane.focus` over the socket, with the pane id already stored.** herdr's socket API
  has `pane.focus {pane_id}` (checked against herdr 0.8.2's schema, protocol 20), and
  every mouse record already carries its pane — it is what `whiska reply` types into.
  So this is one more method on `Whiska.Herdr`, mocked at the same boundary as the rest
  (ADR-0031), and no new data.
- **Nothing waiting is a normal answer.** `whiska jump` with an empty list prints
  `nothing waiting` and exits 0. The hotkey is pressed on spec, and a non-zero exit would
  make a Raycast script report a failure for the case where everything is fine.

## Why this is not new ground, quite

`specs/spec.md` already describes `whiska goto <project>` — "asks herdr to focus that
project's main session pane directly, from wherever you currently are" — so focusing a
pane was designed for from the start and no recorded decision forbids it. What was never
written down is *which* pane and *who* may ask, and those are the two parts worth
recording: the mouse rather than the main session, and the person rather than the owl.
`whiska goto <project>` remains unbuilt and is still a sensible companion; it focuses a
whiska, this focuses a mouse.

Checked and not in conflict: ADR-0020 (mice stay herdr panes — this uses the same
boundary for the same reason), ADR-0008 and ADR-0009 (delivery: untouched, jumping
neither delivers nor closes anything), ADR-0041 (the nudge stays the owl's only
cross-house move), ADR-0038 (the doctor never repairs — this is not the doctor),
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
- `Whiska.Herdr` gains `focus/2`; `Whiska.Herdr.Socket` implements it as `pane.focus`.
  Every mock of the behaviour gains it too, which is the whole cost of the boundary.
- Neither command gets a slash-command skill. ADR-0022 splits the surface three ways and
  puts the machine-wide commands — its examples are `projects` and `goto` — outside the
  set a Claude session runs on the person's behalf. `jump` is the sharpest case of that:
  a session that ran it would yank the person's screen somewhere they did not ask to go.
- The Raycast script is not shipped and nothing is written into anyone's dotfiles. The
  five lines it takes are in `whiska --help` under `jump`, to be copied by hand.
