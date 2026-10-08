# The person decides what reaches them: away, focus and hold

Three things the person sets, each stored at the scope it belongs to, and one rule that
reads all three before the delivery gate does (ADR-0008).

- **Away is the machine's.** One file under the whiska home. While it exists nothing is
  delivered to any main session, mice keep working, and `inbox` keeps listing with `away`
  on its first line. Stepping away from the desk is one word, not one per repo, and one
  `resume` ends it from anywhere. No owl is needed to set or clear it.
- **A focus is one repo's.** The focused mouse's id on the house's own row. Only its
  questions reach that repo's main session; the rest wait, still listed and still counted.
  A branch lives in a repo, so the setting does too.
- **A hold is one mouse's, and a stored status.** `held_at` on the mouse record, not a
  line of text, so it survives an owl restart and shows wherever the mouse is listed. The
  mouse is stopped through the hook, which refuses its next write or shell command with a
  reason that says to end the turn here and say where it stopped; a read passes until
  then, or until the turn ends on its own. Nothing is typed into its pane to stop it. The
  message it ends on sits in the inbox marked `held`, never delivered and never counted
  as waiting on the person: they parked it. A held mouse is never offered a finish, never
  taken down by cleanup (ADR-0061) and never picked up (ADR-0067).
- **The queue is judged against all three first** (`Whiska.Delivery.Mode`), then the gate
  decides as before. A `sent` question whose mouse is held, or is not the focused mouse
  while a focus is on, does not hold the one slot: a hold that left the queue wedged
  behind the very question the person set aside would be no hold at all. It stays `sent`,
  since nothing is delivered twice.
- **Oldest first, always.** After `resume`, what waited arrives in the order it was asked.
- **`resume`** ends away and, inside a repo, that repo's focus; outside any repo it ends
  every repo's focus, naming each. **`resume <branch>`** lifts that mouse's hold and types
  one carry-on line only when the mouse's latest question was asked after the hold began,
  which is a mouse the hold stopped. One that was waiting on an answer when held gets no
  line, and the output names the question to reply to; a reply to a held mouse's question
  lifts the hold itself, since the hook would otherwise refuse the turn the answer starts.
- **A change of mode is noticed within about two seconds.** The person sets it from a CLI
  process that cannot reach the owl, so the tick that rebuilds the sidebar lines compares
  the mode with the last one read and attempts a delivery when it moved.

## The problem it answers

Delivery had one rule and no off switch. A mouse told in conversation to hold kept
finishing its turns, each one delivered and each offering the finish again, because a hold
existed only as a line of text the mouse had read.

## The words

Eight one-word commands, each a spelling of a `whiska` command: `inbox` (`waiting`, with
why each row waits), `show` (`questions --full`, or one by id), `reply`, `dismiss`
(`close`), `focus`, `away`, `hold`, `resume`. The long names keep working. `jump` gets no
one-word command, and `show`, `reply` and `dismiss` are this repo's only: question ids
repeat across repos, and a cross-repo `show 12` would have to guess.

`whiska init --global` installs them into a directory of Whiska's own under the whiska
home, which the person adds to PATH once. A word that already resolves to another program
on PATH is skipped and named, never shadowed, and `whiska doctor` warns where a word
resolves to anything but Whiska's own wrapper. The same eight are slash commands in the
main session, each a thin wrapper around the fixed command (ADR-0022).

**The person's commands are refused to a mouse.** `Whiska.Rule.Persons` runs in the hook
beside the held rule: a mouse's shell command whose head word is `away`, `hold`, `focus`,
`resume`, `reply`, `dismiss` or `close`, with `whiska` in front or bare, is refused with
the reason that those are the person's to run. The eight skills land in every mouse's
session too, so a sentence in a skill was the only thing stopping a mouse from putting the
machine away or holding a sibling; what must hold goes in the hook (ADR-0011). Reading
commands (`inbox`, `show`, `questions`, `waiting`, `mice`) are anyone's.

## What is said where

- herdr's tab bar: `🦉 watching · away · 🐱 2 whiskas`. Nothing per repo, since the bar is
  one line for the machine.
- A mouse's sidebar line says `waits: away` or `waits: focus on <branch>` where it would
  say `queued behind #n`, and `⏸ held` for a held mouse (ADR-0082). Held questions are
  listed by `inbox` and `whiska questions` marked `held` and are not counted as waiting on
  either status line; questions waiting behind away or a focus are.
- **The gate's word is "gated."** Delivery stopped by the person's own busy prompt box or
  mid-turn session reads `gated: your prompt box isn't empty`, on the main checkout's
  sidebar line and in `whiska doctor`. "Held" means one thing: a mouse the person put on
  hold.

## Consequences

- `held_at` on the mouse record and `focus` on the house row; away is a file, read by the
  owl, the tab bar and every listing.
- `Whiska.Delivery.Mode` is the one place that says what may be delivered and why a
  question waits; the house, the sidebar lines, `whiska questions`, `inbox` and the tab bar
  all read it, so they cannot disagree.
- `Whiska.Rule.Held` runs before the sniff rule in the hook, and a database that will not
  open falls back to not held, the direction every fallback there takes.
- `whiska doctor` warns about any file in the commands directory that is not one of
  Whiska's own wrappers, and `whiska init --global` and `away` refuse to write through a
  symlink where their file would go, since a build mouse may write under the whiska home.
- A finished branch lands by cherry-picking its own commits onto the current branch,
  oldest first, skipping its merges from the base, then running the repo's checks and
  dropping the worktree. A `## Finish` heading names it as `finish: land here`.

## Considered options

- **Away per repo.** Rejected: leaving the desk would mean typing it in every repo.
- **Focus machine-wide.** Rejected: a branch is one repo's; silencing other repos is what
  `away` is for.
- **Typing "stop" into the held mouse's pane.** Rejected: it lands after the current turn
  ends, stops nothing mid-turn, and costs a turn to read. The hook stops the next tool
  call, as close to "where it is" as a session can be stopped.
- **Wiring the hold rule to every tool, so a read stops too.** Not done: it would charge
  every read of every mouse the hook's startup; the rule module refuses whatever it is
  asked about, so it needs no code if the person wants it.
- **Newest-first delivery after a resume.** Rejected: an old question could wait forever.
- **Ids unique across repos.** Rejected: it changes every id and every delivered line for
  a command the person wants repo-scoped; `inbox` is the cross-repo view.
- **The words in `~/.local/bin`.** Rejected: eight generic names in a shared directory.
- **Keeping `/whiska-questions` and `/whiska-reply` beside the new skills.** Rejected:
  twelve Whiska skills in every session's context, two of them saying what two others say.
