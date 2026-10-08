# `whiska jump` moves the person's focus, and lands on the house's main session

Whiska may take the person's focus only when the person asked for it in that same breath:
`whiska jump`, typed or fired from a hotkey they bound. Nothing else in Whiska calls
herdr's `pane.focus`, not delivery, not the backstop, and above all not the owl, which has
no cross-house move at all (ADR-0044). An owl that could pull the screen around would be a
much worse thing than one that can type a line.

## Decision

- **A jump lands on the house's main session, never a mouse's pane.** The person does not
  work in a mouse's pane; they act from their own, the one `whiska start` recorded, where
  the `🐱` line was delivered and the reply is typed. A mouse's pane is mid-turn with
  nothing to type into that would not interrupt it. This was first decided the other way
  round and reversed the day after it was built: context is not what the hotkey is for.
- **`whiska jump`** goes to the house of the oldest entry in `whiska waiting`; nothing
  waiting prints `nothing waiting` and exits 0, since the hotkey is pressed on spec and a
  script must not report a failure. **`whiska jump <repo|branch>`** goes to that house's
  main session, waiting or not: a bare word is a repo first, then a branch, looked for
  across every recorded house, since neither name says which project it belongs to. A house
  with no main session recorded is said out loud, exit 0, naming `whiska start` as the fix.
- **`whiska open <id|branch>` is a separate move, into that mouse's own pane**, because the
  person named the mouse. The pane is found by its folder in herdr's pane list, not from
  the stored pane column (ADR-0061). No pane but a worktree on disk: `worktree.open` with
  focus, a workspace on a shell. Worktree gone: says so with the commit count. Branch gone:
  landed or dropped. All exit 0. No option on a finished question offers it; the person
  talks to a finished mouse from the main session (ADR-0022).
- **`/inbox` is the slash command for what is waiting; `jump` has none.** A typed slash
  command is the person asking in the same breath. A session that could move their screen
  on its own judgment is the sharp case this record is written against.
- **`whiska waiting` reads the open-houses record without the owl** (ADR-0039 guards the
  word "open", not the listing): a question already recorded is waiting whether or not
  anything is awake, and a dead owl is when the person most needs to be told what piled
  up. One bad house must not sink the listing: a house that will not open or answer is
  shut down, said once on stderr, and skipped, since silence would read as that repo
  being quiet.

## Consequences

- `Whiska.Waiting` is the one reading of "waiting", shared with the tab bar (ADR-0048), so
  the two cannot disagree. Every entry still carries its mouse's pane, which `whiska reply`
  types into; it is not where a jump goes.
- `Whiska.Herdr` gains `focus/2` and `open_worktree/2`, faked at the same boundary
  (ADR-0031).
- The hotkey runs without a shell environment (a Raycast script command running
  `open -a kitty && whiska jump`), so `HERDR_SOCKET_PATH` is unset there as it is for the
  supervised owl; `Whiska.Herdr.socket/1` falls back to herdr's default socket.
- The Raycast script is not shipped; its five lines are in `whiska --help` under `jump`.
- Neither the tab bar nor a statusline can make this a click: Claude Code strips links
  from a statusline and herdr's tab bar has no click action.

## Considered options

- **Land on the mouse's pane.** Built, then reversed: the person arrives mid-transcript
  with nothing to do but read, then switches again to answer.
- **Let the owl jump when something arrives.** The owl types a line and nothing more;
  moving the screen is the person's.
- **A slash command for `jump`.** Dropped by the person from the one-word set.
