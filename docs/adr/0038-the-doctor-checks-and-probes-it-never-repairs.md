# The doctor checks and probes; it never repairs

`whiska doctor` was one sentence in the spec: "is the owl running, is this repo's house
open and its hooks correctly installed, does the marker file look right, is herdr
reachable." Building it forced two decisions the sentence did not make.

## Why it exists now

The bash relay that used to tell the main terminal about a waiting question is gone
(ADR-0029). Delivery now exists — the owl types a question into the main session when
that session is idle — but nothing reports the cases where delivery cannot happen: the
owl is down, no main session was ever recorded, the recorded pane stopped running
Claude, the installed binary cannot serve the Stop hook. The owl logs those to its own
stderr, in whichever pane started it, which is the "one person who needs to know is the
one it cannot reach" problem ADR-0036 names. The statusline that ADR-0027 makes the
home for "the owl is down" is still unbuilt. So from the main terminal, a broken pipe
and a quiet fleet look identical: silence. The doctor is the command you run to learn
which silence you are in.

That fixes the problem it is for. It is not first-time setup, though it covers that as
the degenerate case where everything fails. It is **drift**: everything was set up once
and has changed since. The evidence that shaped it, all found on the development machine
the day it was built: a binary rebuilt but not reinstalled, so the installed one did not
know `hook stop`; three repos whose `init` predated the Stop hook, each with the old
no-argument shim; an owl that had never been started; a house with no main session
recorded; mouse records for two worktrees that no longer existed. Not one of those was a
mistake anyone made. All of them were silent.

## It checks and never repairs

Every failing check prints the exact command that fixes it — `whiska init`, `whiska owl`,
`mix escript.build && cp whiska ~/.local/bin/whiska` — and the doctor runs none of them.

Repairing was considered, both by default and behind a `--fix` flag. Rejected for now:
rewriting `settings.json` is `init`'s job and already has its own idempotency and
refusal rules; replacing the binary is the installer's; reconciling mouse records is the
owl's (ADR-0026). A doctor that repairs re-implements a piece of each, and then has to be
trusted not to do the wrong one. A doctor that prints the command is one step from
`--fix`, and that step can be taken once the fix list has stopped changing.

The consequence people will rely on: **running the doctor is side-effect free.** It
opens the house's database, which migrates it if it is behind — that is `Storage.open`'s
standing behaviour and not something the doctor adds — and otherwise reads. This is the
same line ADR-0036 draws for collection ("reads and marks; never deletes and never
touches the worktree"), drawn one notch tighter: the doctor does not even mark.

## It probes rather than inspects

Reading `.claude/settings.json` proves a hook is wired. It does not prove the shim finds
an Erlang runtime, or that the binary the shim finds knows the hook it is being asked
for. Both of those were the actual failures on the day. So the doctor runs the repo's
real shim, once per hook, with a synthetic payload whose `cwd` is a fresh temporary
directory outside any worktree. Outside a worktree, `pre-tool-use` allows and `stop` is
a no-op, so both hooks run their whole resolution path and write nothing — no marker
minted, no doorstep entry, no mouse record. ADR-0035 already says the shim's resolution
"is verified by running the installed hook end to end rather than by unit test"; the
doctor is that verification, on demand.

Because the shim fails open by design (ADR-0035), exit 0 is not success. The shim's own
complaint on stderr — "whiska: not found - allowing the call" — is what tells the doctor
the call was allowed by accident, and that is reported as a failure.

One thing the probe cannot see: the old no-argument shim runs `pre-tool-use` whatever it
is told, and `pre-tool-use` outside a worktree is silent. So the shim is also compared,
byte for byte, with what `init` writes today, and any difference fails. The two checks
cover each other.

## Scope

One repo, run from its main checkout or any worktree. The binary, runtime, herdr and
owl are reported alongside, because they are that repo's prerequisites: a wired Stop
hook is worth nothing if the installed binary cannot serve it. Machine-wide — "every
house" — was considered and is blocked rather than rejected: nothing on the machine can
list every house until the owl's global socket exists (ADR-0025). When it does, that is
one query, and the doctor can also stop guessing at the owl from the process table.

## The main session and the queue

Delivery added the one thing about a house that is neither a mouse nor a question: the
pane `whiska start` recorded as the main session. The doctor judges it with the same
herdr call the delivery gate uses, so the two agree on what "running Claude" means, and
it reports every bad state — not recorded, pane gone, pane not running Claude — as a
warning, because the owl holds the queue and nothing is lost. It also prints the queue
as a diagnosis rather than a listing (`whiska questions` is the listing): how many are
open, whether one is sent and for how long, and a warning for the one combination that
means nothing can move — open questions with no main session to deliver them to.

## What is a failure

**fail** means a question from a mouse in this repo would be lost or never written: a
hook not wired or at an older version, a shim that differs, a binary that cannot serve
the hook, a house that will not open. **warn** means degraded but nothing is lost: the
owl is down and entries are waiting, the binary is only in the fallback location, herdr
cannot be asked, no main session is recorded, a mouse record no longer matches the
worktree or has no live pane.
Owl-down is a warning and not a failure on purpose — ADR-0036 made the doorstep the
reason it is not a loss — but the warning carries the waiting count and the oldest
entry's age, so "3 waiting, oldest 40 min" reads as urgent without redefining the levels.
Exit status is non-zero on any failure and zero on warnings alone, so a script can ask
without reading the text.

## The honest limit

ADR-0008 rejected a startup check inside `whiska start` because a one-shot check "catches
the least likely moment and misses the likely one". The doctor has the same limit and
makes no claim otherwise: it reports the moment it is run. It is not monitoring, and it
does not replace the statusline that ADR-0027 says is where "the owl is down" belongs.
It is the thing to run when the statusline is not there yet.
