# The person decides what reaches them: away, focus and hold

Three things the person sets, each stored at the scope it belongs to, and one rule that
reads all three before the delivery gate does (ADR-0008).

- **Away is the machine's.** One file under the whiska home. While it exists nothing is
  delivered to any main session, mice keep working, and `inbox` keeps listing with `away`
  on its first line. Stepping away from the desk is one word, not one per repo, and one
  `resume` ends it from anywhere. No owl is needed to set or clear it.
- **A focus is one repo's.** The focused mouse's id on the house's own row. Only its
  questions reach that repo's main session; the rest wait, still listed and still counted.
  A branch lives in a repo, so the setting does too. A letter from another repo's main
  session is no mouse's, so a focus does not hold it; away does (ADR-0008).
- **A hold is one mouse's, and a stored status.** `held_at` on the mouse record, not a
  line of text, so it survives an owl restart and shows wherever the mouse is listed. The
  mouse is stopped through the hook, which refuses its next write or shell command with a
  reason that says to end the turn here and say where it stopped; a read passes until
  then, or until the turn ends on its own. Nothing is typed into its pane to stop it. The
  message it ends on sits in the inbox marked `held`, never delivered and never counted
  as waiting on the person: they parked it. A held mouse is never taken down by cleanup
  (ADR-0061) and never picked up (ADR-0067).
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

Eight one-word commands, each a spelling of a `whiska` command: `inbox` (`waiting`
narrowed to this repo, with why each row waits; `inbox --all`, or `inbox` outside any repo,
lists every repo), `show` (the one question delivered and waiting on the person, in
full, or any one by id), `reply`, `dismiss` (`close`), `focus`, `away`, `hold`, `resume`.
The long names keep working.

`show` with no id once meant `questions --full`, every open question in full. Seen live: a
delivered line said `1 more open`, the main session ran bare `show`, and the question
queued behind the delivered one reached the person in full before its turn, which undoes
the queue (ADR-0008). So bare `show` prints only the delivered one, the oldest `sent`
question the mode lets through, or a line saying nothing is delivered and pointing at
`inbox`. `inbox` stays the overview of everything, queued and held included, a line each;
`questions --full` still prints them all in full for whoever asks by that name. `jump` gets no
one-word command, and `show`, `reply` and `dismiss` are this repo's only: question ids
repeat across repos, and a cross-repo `show 12` would have to guess. `inbox` is repo-scoped
for the same reason: the person reads it from inside one repo, and the same ids in another
repo's rows would invite that guess. `waiting` stays machine-wide.

`whiska init --global` installs them into a directory of Whiska's own under the whiska
home, which the person adds to PATH once. A word that already resolves to another program
on PATH is skipped and named, never shadowed, and `whiska doctor` warns where a word
resolves to anything but Whiska's own wrapper. In the main session the person says them
in words, and its brief names the command each runs (ADR-0088).

**The person's commands are refused to a mouse.** Every shaped mouse starts with a deny
rule for each: `away`, `hold`, `focus`, `resume`, `reply`, `dismiss` and `close`, with
`whiska` in front or bare, and `whiska spawn`, `send`, `tell`, `land`, `pr`,
`merge-request` and `drop`, only with `whiska` in front since `pr` and `send` are other programs too. Prose in
a brief would be the only other thing stopping a mouse from putting the machine away,
holding a sibling, or starting, landing or throwing away a branch; what must hold is a
rule Claude Code enforces (ADR-0011, ADR-0090). A plain rule matches the command as
written, so `env`, a full path or `bash -c` gets round it. Reading commands (`inbox`,
`show`, `questions`, `waiting`, `mice`, `ledger`) are anyone's.

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
- `Whiska.Rule.Held` is the one rule the hook runs, and a database that will not open
  falls back to not held.
- `whiska doctor` warns about any file in the commands directory that is not one of
  Whiska's own wrappers, and `whiska init --global` and `away` refuse to write through a
  symlink where their file would go, since a build mouse may write under the whiska home.
- A finished branch lands by `whiska land`, on the person's word: its own commits
  cherry-picked onto the current branch, oldest first, its merges from the base skipped,
  then the repo's checks. The owl takes the worktree down once it sees the work in the
  base (ADR-0061).

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
  a command the person wants repo-scoped; `inbox --all` and `waiting` are the cross-repo view.
- **`inbox` machine-wide by default.** Rejected: from inside a repo it buried that repo's
  rows under other repos' with colliding ids; `--all` keeps the wide view one flag away.
- **The words in `~/.local/bin`.** Rejected: eight generic names in a shared directory.
- **Keeping `/whiska-questions` and `/whiska-reply` beside the new skills.** Rejected:
  twelve Whiska skills in every session's context, two of them saying what two others say.

Changed on 2026-10-13: the one-word commands have no slash commands, and `spawn`, `send`,
`land`, `pr` and `drop` are the person's too (ADR-0088).

Changed on 2026-10-14: the person's commands are deny rules a mouse starts with, not a
rule in the hook (ADR-0090).

Changed on 2026-10-14: `merge-request` is the person's too. The owl reads the link it
records every minute and asks about the branch when it closes (ADR-0060), so recording one,
for any branch, is the person's to do, as opening one with `pr` already was.

Changed on 2026-10-15: `tell` is the person's too, and a letter from another house waits
for away but not for a focus (ADR-0044).
