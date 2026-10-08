# Questions are left on the doorstep, whoever writes them

Every finished turn lands on the house's doorstep as a file, and the doorstep is the one
way a question gets into a house: nothing reaches the database except by being collected
from it. The mouse's `Stop` hook asks the owl first, over the hook socket (ADR-0033); the
owl runs `Whiska.Hook.Stop` with the hook's own environment, writes the entry, and asks
the open house to collect it at once. When the owl does not answer, the escript writes the
same entry in the same format. One module decides what is written, run in one process or
the other, and nothing about the state of the owl changes whether a turn's message is
written.

The doorstep is a directory in the house, `<main-checkout>/.git/whiska/doorstep/`, beside
the database. Each entry is stamped with `mouse_id`, branch label and timestamp, written
to a temporary name and renamed into place so the owl never reads a half-written file.
Collected entries are renamed `.collected` rather than deleted (ADR-0007), so `ls *.json`
on the doorstep is exactly what is still waiting, answerable with no database and no owl.

## Why a file, and why in the house

A hook that connected to a socket would have to answer what to do when nothing is
listening, and "fail loudly" has no target: the hook's stderr lands in the mouse's own
transcript, seen by nobody who needs to know. A file write has no connect timeout, no
retry and no second code path for a dead owl, which still loses nothing.

The doorstep sits in the house, not the worktree, so an ordinary `drop-worktree` cannot
silently erase pending questions. The mirror cost is that a question can outlive its mouse;
that state has a name already (ADR-0026), and delivery releases such a question as settled
or orphaned rather than typing it (ADR-0008). `.git/whiska/` is gitignored by construction.

## Collection is event-driven; the timer is only a backstop

herdr's own hook marks a pane idle when a turn ends and emits a status event; the owl
subscribes to that, so it is woken at the moment there is something to collect.

| Trigger | Role |
|---|---|
| a mouse pane's status event, `done` or `idle` | primary: collect that house's doorstep now, and again after 2 s and 5 s if it was empty |
| the hook socket answering a `Stop` | collect at once, beating the event |
| owl open | collects whatever landed while it was down |
| slow timer, 60 s | backstop only |

The retries exist because Claude Code runs its `Stop` hooks in parallel, so herdr's event
can arrive before Whiska's entry is written. The backstop cannot be dropped: herdr can be
down while the owl is up, and subscriptions drop when herdr restarts. Two herdr facts the
house encodes: a per-pane subscription event arrives under the dotted spelling
(`pane.agent_status_changed`) while global events use underscores, and a mouse working in
a background tab ends its turn as `done`, with `idle` following only when someone looks
at it. The house folds both into one reading.

**The backstop announces itself.** For weeks every collection ran on the backstop while a
mis-spelt event never matched, and nobody noticed: every question did arrive, a minute
late, and a minute late is invisible. A last resort silently doing the trigger's job is
indistinguishable from a healthy system. So when the backstop's collection finds anything,
the house prints one warning naming the house and the count, and leaves a mark, a count
and a timestamp in `<main-checkout>/.git/whiska/backstop`, cleared when the owl opens the
house. `whiska doctor` turns the mark into one line, pointing at the subscription and at
restarting the owl. Collecting at open and the idle trigger's own retries do not count.
The mark is in the house because it is one house's fact and the doctor is scoped to one
repo, and per-house files mean no two houses rewrite the same one.

**The subscription is per pane, so the house has to know its panes.** herdr subscribes to
status for a named pane only, so a house finds each mouse's pane by matching the pane's
`cwd` to the mouse's worktree, at open and whenever herdr reports a new agent pane, and
reopens its subscriptions when that set changes. A mouse with no pane anywhere is a dead
mouse (ADR-0026).

## What the hook does not write

Two things narrow "every turn", and both are about whose turn it is, never about the
state of the house. A turn with a background subagent still out has not ended, so nothing
is written (ADR-0052). A stop firing in the pane `whiska start` recorded as the main
session is the person's own, not a mouse's, and writes nothing (ADR-0053); that read runs
through `Whiska.Isolated`, so a database that will not open cannot take the hook down
before it writes.

There is one `Stop` entry in `settings.json`, naming the shim. Anything that wants to run
in front of this hook chains inside the shim, never as a second entry: Claude Code runs
`Stop` hooks in parallel and does not order them, and a second entry once reported a turn
"finished" seconds before the mouse was done. The doctor's `stop` probe carries no `done`
marker, because a probe that looks like a finished turn lies.

One edge, accepted: when the owl writes the entry and the shim gives up waiting before the
answer arrives, the escript writes a second entry for the same turn, and the newer
supersedes the older (ADR-0008), so the person sees one question.

## Considered options

- **Auto-start the owl on demand** with `launchd` socket activation. Rejected: a hook
  silently spawning a long-running service, and a crash-looping owl hard to notice.
- **Block the mouse until the owl is reachable.** Rejected: the whole fleet wedges because
  a notification service is down, inverting the trade `PreToolUse` makes by allowing a
  call its payload cannot be read for.
- **Write the file, then poke the owl with a fire-and-forget datagram.** Deferred rather
  than rejected; the hook socket now does that job.
- **Watch the filesystem.** Rejected: watchers miss events under load and need a periodic
  reconcile anyway, so the backstop gets built regardless.
