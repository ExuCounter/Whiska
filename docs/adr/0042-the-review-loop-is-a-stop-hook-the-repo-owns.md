# The review loop is a Stop hook the repo owns, not a Whiska feature

A mouse marking itself `done` is its own opinion, and ADR-0014 tried to answer that with
`.whiska/checks.yml` — a check list Whiska would own, parse, run and report on, at push
time. That is superseded. **What decides whether a turn is actually over is a Claude Code
`Stop` hook belonging to the repo**: `.claude/hooks/review-loop.sh`, a shell script with
the repo's own check command written at the top of it.

`whiska init` writes the file and its `settings.json` entry the same way it writes the
shim (ADR-0035, ADR-0016), and then never touches it again — not on a re-run, not on
`whiska update`. Whiska never reads its contents. It is one more per-project hook that
happens to be installed by the same command, and Whiska stays exactly as dumb as ADR-0017
requires.

## What the loop does

When the mouse's final message ends on `[worktree-status: done]`, and only then:

1. **Run the check command.** If it fails, block the stop — `{"decision": "block",
   "reason": "<the failing output>"}` — so the mouse fixes it and finishes again, in the
   turn where the fix is still cheap.
2. **If it passes and this is the first stop of the turn** (`stop_hook_active` is false),
   block exactly once with a fixed reason: read your own diff back against `specs/` and
   `docs/adr/`, fix what contradicts a recorded decision, say in one line what you found.
   One guaranteed review pass, every time, whether or not the mouse thinks it needs one.
3. **Otherwise let the stop through.**

A turn ending on `needs-decision` is never blocked — it is waiting on the person, and
holding it hostage to a green suite would strand them. A turn with no marker at all is
never blocked either: that is already something the owl reports (ADR-0009), and blocking
would talk over it.

**The loop is bounded, in ADR-0011's shape and for its reason.** At most two blocks in a
row for failing checks; the third time the stop goes through, and the failure reaches the
person through the doorstep instead of looping until someone happens to look. `CHECK` also
gets a `TIMEOUT` — a `Stop` hook that hangs hangs the pane.

The two facts that have to survive between the stops of one turn — how many failures in a
row, and whether the review pass has been asked for — are two lines in a file under
`$TMPDIR`, keyed by `session_id`. `stop_hook_active` being false is what a turn boundary
looks like from inside a hook, so that is where both reset.

## Why a hook, and why the repo's

**Why at the end of a turn rather than at push.** A failing test found at push time is
found after the mouse has committed and moved on; found at the end of the turn, it is
still the thing the mouse was just doing. The `Stop` hook is at that boundary by
construction, and it is the only place Claude Code lets anything say "not yet".

**Why the repo owns it.** The alternative was Whiska owning the loop, which is what
`checks.yml` was. Every repo already says how it is checked — in `CLAUDE.md`, in its
scripts, in whatever gate it pushes through — and a second place to say it means the
answer depends on which file you opened. Worse, owning it drags Whiska into judgment:
which checks are advisory, which run only on push, what counts as a real failure. A shell
script the person edits has none of that, and a repo that wants `make ci`, `no-mistakes`
or a `gh`/`glab` call writes exactly that on one line.

**ADR-0015 still stands.** "No automated diff review — the human is the review" is about
*Whiska* reading a diff and judging it, and about push approval. Nothing here reads a
diff: the hook makes the mouse read its own, and the human is still the review at push.
What moved is where the mechanical layer sits — a turn earlier, before the commit exists,
outside Whiska.

## Considered options

**Keep `checks.yml` and run it at push.** Superseded — see ADR-0014 for the full
reasoning. In short: a second configuration surface for something the repo already states,
timed too late to be cheap to fix.

**A `whiska review` command the mouse is told to run.** Rejected: it is a rule in
`CLAUDE.md`, and a rule a mouse may or may not follow is exactly what ADR-0010 says to
make mechanical when it matters. A hook that can actually block is mechanical.

**Put judgment in the hook** — parse the diff, decide whether a review is warranted, vary
the prompt. Rejected on the same grounds as everything else here. The hook has one fixed
sentence in it; the judgment belongs to the model that reads it.

**Drive it from CI.** There is no CI on this repo today, and a loop that only closes after
a push is not a loop that catches anything in the turn. Nothing here depends on `gh` or
`glab`; if CI arrives it is a second layer, not this one.

## Consequences

**A green turn now takes at least two stops.** The review pass is unconditional, so every
finished turn pays one extra round trip even when there was nothing to find. That is the
cost, knowingly: a review that only runs when something looks wrong is a review that never
runs.

**The check runs on every `done` turn, not once per branch.** A slow suite is felt every
time. `TIMEOUT` bounds the damage but does not remove it, and the answer if it bites is to
make `CHECK` cheaper — a fast subset — rather than to make the hook cleverer.

**Killing a check kills the shell, not necessarily its children.** The watchdog sends
`TERM` to the `bash -c` it started; a suite that has forked leaves the children behind. A
process group would need `setsid`, which is not on a stock macOS. Recorded as an honest
limit rather than pretended away.

**`jq` is a hard dependency of the loop**, since the last assistant message can be
anything and there is no honest way to pull it out of the JSON without one. Missing `jq`
fails open, loudly, on stderr — the same trade the shim makes for a missing Whiska binary.

**The doctor does not check it.** `whiska doctor` checks Whiska's own prerequisites
(ADR-0038), and this file is the repo's. Deleting it is a thing a person is allowed to do
without Whiska complaining.

**In the main checkout it is inert.** A main-session turn does not carry a worktree-status
marker, so the hook exits before running anything. No worktree detection was needed to get
that; it falls out of the marker being the trigger.

## The open seam: this races Whiska's own `Stop` hook

Claude Code runs every `Stop` hook in parallel. Whiska's writes the mouse's final message
to the doorstep unconditionally (ADR-0036), and the owl delivers it within seconds — so
when the review loop blocks the stop, the person is told the mouse **finished** while it
is still looping. What lands on the doorstep next turn supersedes it (ADR-0037), so
nothing is lost, but the first report is wrong while it stands.

This is a known wart at the time of writing, not a decision. Closing it means something
reading the marker before the doorstep write, which bends ADR-0036's "it does not
classify", and that is a change to make deliberately rather than in passing. Until it is
made, the loop and the doorstep run side by side.
