# The person decides what reaches them: away, focus and hold

**Amends [ADR-0008](0008-delivery-is-a-queue-not-a-batch.md)** (the one slot gains two
exceptions), **[ADR-0057](0057-nothing-unanswerable-holds-the-delivery-slot.md)** (a held
or unfocused `sent` question does not hold it either),
**[ADR-0058](0058-a-held-queue-says-so-on-the-board.md)** (its word is now "gated"),
**[ADR-0061](0061-a-merged-worktree-is-taken-down-by-the-owl.md)** and
**[ADR-0067](0067-a-turn-that-died-is-picked-up.md)** (a held mouse is skipped by both
sweeps), and **[ADR-0022](0022-each-command-gets-a-slash-command-skill.md)** and
**[ADR-0043](0043-whiska-jump-moves-the-persons-focus.md)** (a machine-wide command may
have a slash command after all, when the person types it).

## The problem

Delivery had one rule and no off switch. Every question from every mouse reached the main
session the moment it was free, one at a time, oldest first, and one mouse's unanswered
question blocked every other mouse's (ADR-0008). Handling them meant typing the long
commands — `whiska waiting`, `whiska questions 12`, `whiska reply 12 "..."`,
`whiska close 12` — and there was no way to say "not now".

A mouse told *in conversation* to hold kept finishing its turns. Each one was delivered,
and each offered the land-or-merge picker again. Nothing in Whiska knew the mouse was on
hold, because a hold existed only as a line of text the mouse had read.

## Decision

Three things the person sets, each stored at the scope it belongs to, and one rule that
reads all three before the gate ever does.

- **Away is the machine's.** One file under the whiska home. While it exists nothing is
  delivered to any main session, mice keep working, and `inbox` keeps listing. Stepping
  away from the desk is one word, not one per repo, and one `resume` ends it from
  anywhere. No owl is needed to set or clear it.
- **A focus is one repo's.** The focused mouse's id on the house's own row. Only its
  questions reach that repo's main session; the rest wait, still listed and still counted.
  A branch lives in a repo, so the setting does too; a machine-wide focus would silence
  repos the branch has nothing to do with.
- **A hold is one mouse's, and a stored status.** `held_at` on the mouse record, not a
  line of text: it survives an owl restart and shows wherever the mouse is listed. The
  mouse is stopped through the hook, which refuses its next write or shell command — the
  tools the `PreToolUse` matcher is wired for — with a reason that says to end the turn
  here and say where it stopped. A read passes until the next of those, or until the turn
  ends on its own; the rule module refuses whatever it is asked about, so wiring the
  matcher to every tool would need no code, only the person's say, since it would charge
  every read of every mouse the hook's startup. Nothing is typed into its pane to stop
  it: a typed line lands after the current turn and costs a turn.
  The message it ends on reaches the inbox like any other and sits there, held,
  undelivered. A held mouse is never offered for landing (its finished line is never
  delivered, so the picker never fires), never taken down by the merged-worktree sweep,
  and never nudged to carry on by the dead-turn pickup: "stops where it is" means that.
- **The queue is judged against all three first** (`Whiska.Delivery.Mode`), then the gate
  decides exactly as before. A `sent` question whose mouse is held, or is not the focused
  mouse while a focus is on, **does not hold the one slot**: a hold or a focus that left
  the queue wedged behind the very question the person set aside would be no hold at all.
  Such a question stays `sent` — it was delivered, and nothing is delivered twice. Once
  the mode is lifted the queue waits behind the oldest `sent` one again.
- **Oldest first, always.** Newest-first was rejected: a newer question from any mouse
  would jump ahead, and old ones could wait forever. After `resume`, what waited arrives
  in the order it was asked.
- **`resume`** ends away and, inside a repo, that repo's focus; outside any repo it ends
  every repo's focus, naming each. **`resume <branch>`** lifts that mouse's hold and
  types one line — the hold is lifted, carry on from where you stopped — only when the
  mouse's latest question was asked after the hold began, which is a mouse the hold
  stopped. One that was waiting on the person's answer when held gets no line, and the
  output names the question to reply to; **a reply to a held mouse's question lifts the
  hold itself**, since the hook would otherwise refuse the very turn the answer starts.
- **A change of mode is noticed within about two seconds.** The person sets it from a CLI
  process that cannot reach the owl, so the tick that already rebuilds the board compares
  the mode with the last one it read and attempts a delivery when it moved. No socket.

### The words

Eight one-word commands, each a spelling of a `whiska` command: `inbox` (`waiting`, with
why each row waits and `away` on its first line), `show` (`questions --full`, or one by
id), `reply`, `dismiss` (`close`), `focus`, `away`, `hold`, `resume`. The long names keep
working. `jump` gets no one-word command: the person dropped it, and `show`, `reply` and
`dismiss` are this repo's only, exactly as the long commands were — question ids repeat
across repos, and a cross-repo `show 12` would have to guess.

They are installed by `whiska init --global`, with the rest of the machine-wide install,
into a directory of Whiska's own under the whiska home — never `~/.local/bin`, where eight
generic words would land among other programs. The person adds that directory to PATH
once. A word that already resolves to another program on PATH is **skipped and named,
never shadowed**; `whiska doctor` reports whether the directory is on PATH — information, not a warning, since
the slash commands do the same job — and warns where a word resolves to anything but
Whiska's own wrapper. `whiska uninstall --global` takes them out.

The same eight are slash commands in the main session, each a thin wrapper around the
fixed command (ADR-0022). They **replace** `/whiska-questions` and `/whiska-reply`, and
`whiska init` removes those two files where they are plain files of Whiska's — a symlinked
one is the person's and stays (ADR-0056). `whiska-delivered` stays: the delivered line
triggers it, nobody types it. Two skill sets saying the same thing would be twelve Whiska
skills in every session's context.

### What the status lines say

- herdr's tab bar: `🦉 watching · away · 🐱 2 whiskas`. The owl, away when set, the count.
  Nothing per repo — no focus, no held mouse — since the bar is one line for the machine.
- The repo's board: `🐱 3 waiting · away`, or `🐱 3 waiting · focus: feat-auth`, with the
  gate's reason after the focus when the focused question is stuck at the gate. A held
  mouse's row says `held` where it said `working` or `idle`. A question waiting behind
  away or a focus says `waits: away` or `waits: focus on <branch>` where it said
  `queued behind #n`.
- A held mouse's questions are listed by `inbox` and `whiska questions` marked `held`, and
  **not counted as waiting on the person** on either status line: they parked them.
  Questions waiting behind away or a focus are still counted.
- **The gate's word is "gated".** CONTEXT.md used "held" for delivery stopped by the
  person's own busy prompt box or mid-turn session (ADR-0058). "Held" now means one thing,
  a mouse the person put on hold, and `held: your prompt box isn't empty` reads
  `gated: your prompt box isn't empty`; `whiska doctor` spells it the same way.

## Consequences

- Migration V010 adds `held_at` to the mouse record and `focus` to the house row. Away is
  a file, read by the owl, the tab bar and every listing.
- `Whiska.Delivery.Mode` is the one place that says what may be delivered and why a
  question waits; the house, the board, `whiska questions`, `inbox` and the tab bar all
  read it, so they cannot disagree.
- `Whiska.Rule.Held` runs before the sniff rule in the hook, and a database that will not
  open falls back to not held — the direction every fallback there already takes.
- `Whiska.Rule.Persons` runs beside it: a mouse's shell command that is one of the
  person's — `whiska away`, `hold`, `focus`, `resume`, `reply`, `dismiss`, `close`, or
  the bare word — is refused, with the reason that those are the person's to run. The
  eight skills land in `~/.claude/skills/`, where every mouse's session lists them, so a
  sentence in a skill was the only thing stopping a mouse from putting the machine away
  or holding a sibling; ADR-0010 wants that in the hook. Reading commands — `inbox`,
  `show`, `questions`, `waiting` — are not refused.
- `whiska doctor` warns about any file in the commands directory that is not one of
  Whiska's own wrappers, since the person is told to put that directory first on PATH
  and a build mouse may write under the whiska home; `whiska init --global` and `away`
  refuse to write through a symlink where their file would go.
- Cleanup gains a fifth precondition and pickup a precondition: not held.
- `whiska-delivered`'s first picker option is **Land here**: cherry-pick the branch's own
  commits onto the current branch, oldest first, skipping its merges from the base, run
  the repo's checks, then drop the worktree and delete the branch. The person lands
  branches this way, and the picker said `merge --no-ff`. A `## Finish` heading names it
  as `finish: land here`.
- CONTEXT.md gains Inbox, Away, Focus and Held (the mouse); the gate's entry is Gated.

## Considered options

**Away per repo.** Rejected: leaving the desk would mean typing it in every repo, and
`resume` would mean something different in each.

**Focus machine-wide.** Rejected by the person: a branch is one repo's, and silencing
other repos over it is what `away` is for.

**Typing "stop" into the held mouse's pane.** Rejected: it lands after the current turn
ends, so it stops nothing mid-turn, and it costs the mouse a turn to read. The hook stops
the next tool call, which is as close to "where it is" as a session can be stopped.

**Newest-first delivery after a resume.** Rejected: an old question could wait forever
behind newer ones, from any mouse.

**Ids unique across repos, so `show 12` could work from anywhere.** Rejected: it changes
every existing id and every delivered line, for a command the person wants repo-scoped
anyway. `inbox` is the cross-repo view; `jump` the cross-repo move.

**Writing the words into `~/.local/bin`.** Rejected: eight generic names in a shared
directory, with nothing to tell them from other programs. A directory of Whiska's own,
and a PATH line the person adds once, keeps the clash check honest.

**Keeping `/whiska-questions` and `/whiska-reply` beside the new skills.** Rejected:
twelve Whiska skills in every session's context, two of them saying what two others say.
