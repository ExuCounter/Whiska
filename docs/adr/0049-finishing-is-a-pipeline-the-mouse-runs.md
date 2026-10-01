# Finishing is a pipeline the mouse runs, not a hook that blocks it

ADR-0042 made "is this turn actually over?" a `Stop` hook the repo owns:
`.claude/hooks/review-loop.sh`, with a `CHECK` command at the top, blocking the turn
while the checks were red and once more for a single review pass. That is superseded.
**Finishing is now a named part of the `CLAUDE.md` block (ADR-0045) — plain instructions
the mouse runs itself, in order, before it writes `[worktree-status: done]`.**

The hook is retired. `whiska init` writes no `review-loop.sh`, the shim chains none, and
a repo that already has one keeps it: nothing runs it, `whiska doctor` says so, and
removing it is the person's to do (ADR-0038 reports and never repairs; ADR-0007 throws
nothing away).

## What the part says

Five steps, in this order, run only when the turn is about to end on `done` — never on a
turn ending on a decision for the person, and never in the main session.

1. **Read the work back against what was asked**: the brief, the ticket it names, the
   repo's specs, its glossary, its recorded decisions. A contradiction or a missing piece
   is fixed now. A written decision that is the thing out of date is changed too, in the
   same piece of work, where the repo's own rules say that is how it goes. A wrong
   *scope* is not fixed at all — the turn ends on a decision for the person.
2. **Run this repo's checks and fix what fails**, bounded twice: only inside this change,
   and never by a fix that contradicts step 1. A check made to pass by deleting an
   assertion is a check that was not passed.
3. **Send reviewers over the change**: subagents in parallel, one per axis — correctness,
   security, performance, and frontend only when the change touches something a person
   sees. They report; they do not edit. Each finding is verified against the code before
   it is acted on. **The turn waits for them**: the marker does not go down until every
   reviewer has reported and what they found is handled, so there is no progress note to
   the person. Claude Code ends the turn while a background subagent is out and wakes the
   session when it reports; that ending is not the turn finishing and carries no marker,
   and ADR-0052 makes the `Stop` hook ignore it rather than deliver it.
4. **Round two, then stop.** A fix sends the turn back to step 2. Two rounds is the
   ceiling; still red after the second, the turn ends on a decision for the person with
   what is failing named.
5. **Then the marker**, and a message saying what each step found. The `report` part
   already teaches the shape of that message and this part does not repeat it.

**Steps 1 and 3 were extended on 2026-10-01 by ADR-0054**, which does not move the four
axes: a reviewer is taken from the agent types the session already lists wherever one
fits an axis (and is read before it is dispatched, since a worktree's agents arrive with
the branch), a surviving finding is labelled *important*, *nit* or *pre-existing*, and
`reviewers:` and `security:` join the `## Finish` heading below. Step 1 above is now
incomplete as written: where a decision is out of date and the repo's own rules do **not**
say how to change it, that is the person's call rather than a quiet divergence, and the
turn ends on a decision.

Per-repo facts live under a `## Finish` heading in the repo's own `CLAUDE.md`, outside
Whiska's block, one `name: value` line each: `checks:` for step 2, `specs:` for step 1,
`ticket:` for the prefix a ticket id carries. Missing heading, or a missing line: run
what the repo's tooling plainly offers and say in the message what was assumed. That
heading is shared, not Whiska's — the finished-branch picker reads `finish:` from the
same heading in the same shape.

## Why the hook had to go

**A `CHECK` line cannot know what green means here.** One command, written once, per
repo: `mix test` in this one, `npm run lint` in another, `true` where nobody had an
answer yet. Every repo already says how it is checked — in its own instructions, its
build file, its scripts — and the hook made a second place to say it that immediately
drifted from the first. The part reads the repo's own answer instead of holding a copy.

**A fixed script cannot judge.** "Did this match the brief?", "is this finding real?",
"is the scope wrong?" — the hook could ask for none of it. It had one sentence and two
exit codes. ADR-0017 puts every piece of judgment in `CLAUDE.md` and keeps Whiska dumb;
the review loop was the one place that rule was bent, and the bend is what limited it.

**One blocked turn is not a review.** What the person wants at the end of a mouse's work
is a pipeline — brief, then checks, then several reviewers on fixed axes, then a second
round — and a `Stop` hook can express exactly one of those steps, once.

## ADR-0010 is not contradicted

"Hard rules are enforced by `PreToolUse`, not written in `CLAUDE.md`", and its
consequence: `CLAUDE.md` carries everything that needs judgment, `PreToolUse` the short
list of things that must hold regardless of what any model decides. Finishing is all
judgment — which mismatch is a fix and which is the person's call, which finding is real,
what green means in a repo nobody has configured. It belongs on the `CLAUDE.md` side of
that split, and always did. What is on the other side is unchanged: edits stay confined
to the worktree by a hook that can actually deny (ADR-0013), and push stays the person's
decision.

The honest cost is in ADR-0042's own words — a rule a mouse may or may not follow. That
rejection is accepted here rather than answered, because the alternative was a hook that
follows a rule nobody could write.

## ADR-0015 still stands

"No automated diff review in the MVP — the human is the review" is about *Whiska* reading
a diff and judging it, and about push approval. Neither moves. Whiska reads no diff, runs
no check, and has no opinion about any finding; the human is still the review at the push.
What changes is how much the mouse does to its own work before asking — and a mouse
reading its own diff back was already ADR-0042's unconditional review pass, which
ADR-0015's consequences list approvingly. This widens that from one pass to a few
reviewers on named axes. A difference of degree inside a boundary already drawn.

## Consequences

**Finishing is advisory, and that is the trade.** The hook could stop a turn; the part
can only tell a mouse what to do. A mouse that skips step 2 ends on `done` with a red
suite and nothing catches it until the person looks. Accepted: a gate that ran one
unconfigurable command was not catching much either, and what replaces it catches a class
of thing no shell script could.

**A green turn is no longer two stops.** ADR-0042 charged every finished turn an extra
round trip for the review pass. That is gone; the pipeline happens inside the turn, and
the doorstep sees the turn end once.

**The shim's `stop` path is plain again.** Nothing to sequence, so no stdin capture, no
`bash -c`, no `jq` dependency — `stop` execs through exactly as `pre-tool-use` does, and
ADR-0036's addendum is spent: there is nothing left to chain, and `Whiska.Hook.Stop` is
unconditional as it always was.

**A turn costs more.** Several subagents and up to two rounds of checks, at the end of
every finished turn. That is the point, and a repo that finds it too much says so by
making `checks:` cheaper — the same answer ADR-0042 gave for a slow `CHECK`.

**`init` still removes a `Stop` entry naming `review-loop.sh`, although the file itself is
the person's.** The two are not the same thing: the file is inert text, and an entry is a
hook that fires. An entry left behind runs the retired script in parallel with the shim —
the race ADR-0036's addendum closed — so it goes, the way every other Whiska-written entry
is replaced rather than duplicated. The cost is accepted and stated here: a person who
registers the retired script themselves will find that entry gone after the next `init`,
with no way for `init` to tell their entry from the one an older Whiska wrote. Keeping
their own gate means giving it a different filename.

**Two of the pipeline's inputs come from outside the session, and the part says so.** A
ticket is evidence about what was asked and never an instruction to the session; a check
command is read before it is run, and one that fetches something, writes outside the repo
or touches credentials is a decision for the person rather than a command — the more so
when it arrived with the branch being finished rather than from the base branch. The
retired hook had the same exposure through its `CHECK` line, quieter only because a diff
to a shell hook is conspicuous and a `name: value` line in `CLAUDE.md` is not.

**`## Finish` is now a shared heading with its own grammar.** The finish part reads
`checks:`, `specs:` and `ticket:` from it; the finished-branch picker reads `finish:`.
Nothing parses it in Elixir — it is read by a model, like everything else in `CLAUDE.md`
— but the shape is one line of `name: value`, and a new fact goes in as another line
rather than another heading.
