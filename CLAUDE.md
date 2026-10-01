# Whiska

An Elixir/OTP coordinator for Claude Code sessions working in isolated git worktrees.
Replaces this dotfiles setup's bash worktree-notification relay.

The design is finished and written down. Read it before writing code:

- `CONTEXT.md` — the glossary. The canonical name for every domain concept.
- `docs/adr/` — every architectural decision, one file each. `docs/adr/README.md` indexes
  them by area.
- `specs/spec.md` — the long-form design narrative. `handoffs/` — session handoffs.

`CONTEXT.md` and the ADRs are the authority. Where the spec and an ADR disagree, the ADR
wins — it is the later, extracted decision.

## ADRs are binding

**Cite the ADR.** When you make a design or implementation choice that an ADR already
covers, name it — "per ADR-0011, the hook denies immediately rather than waiting". Not
decoration: it is how the next reader knows the choice was inherited rather than invented
on the spot.

**Never contradict an ADR silently.** If the right thing to do now conflicts with a
recorded decision — or you find yourself about to write code that quietly does something
else — stop and say so before writing it. Give exactly this, in one message:

1. Which ADR, by number and title.
2. What it currently says, quoted.
3. What you want to do instead, and why the ADR's reasoning does not hold here.
4. **What behaviour actually changes** if we go your way — the user-visible consequence,
   not just the code shape.
5. Your recommendation.

Then wait. The user decides whether the attempt is right. This is not a rubber stamp
step: an ADR being wrong is a normal outcome, and the point is that it gets changed
deliberately, in the file, rather than drifting out of date while the code walks away
from it.

If the decision changes, the ADR changes in the same piece of work — supersede it or
rewrite it, and update `docs/adr/README.md`. A stale ADR is worse than none.

**Writing a new one** needs all three to be true, or skip it: hard to reverse, surprising
without context, and the result of a real trade-off with genuine alternatives. Scan
`docs/adr/` for the highest number and increment.

## Use the repo's words

`CONTEXT.md` is the glossary — Whiska, mouse, `mouse_id`, question, house, owl, build
mode, sniff mode. Use those names in code, comments, commit messages, and conversation.
Don't invent synonyms, and don't reach for the `_Avoid_` words listed under each term;
they are listed because they were rejected for a reason.

## Keep the architecture diagrams honest

`docs/architecture/` holds C4 diagrams of the system — context, containers, components,
two flows, deployment. They are a *view* onto `CONTEXT.md` and the ADRs, never a third
source of truth: where a diagram and an ADR disagree, the ADR wins and the diagram is the
thing that is wrong.

**If the architecture moves, the diagram moves in the same piece of work** — same rule as
an ADR, for the same reason. A stale diagram is worse than none. The architecture has
moved when any of these is true:

- A new container, component or stored thing exists, or one is gone.
- A boundary moved — something changed which process, socket or file it lives behind.
- A documented flow reordered, gained a step, or lost one.
- A piece crossed from "designed, not built" to built. `docs/architecture/README.md`
  keeps that split, and it is the part that rots fastest.

A change that touches none of those is a normal outcome. Say so in one line rather than
editing a diagram to look busy.

### Mermaid, specifically

The diagrams must actually render. Two traps that have already been hit:

- **`C4Dynamic` numbers its own relationships**, in declaration order. Never write `"1. "`
  into a `Rel` label — it renders as `1. 1.`. Order the `Rel` lines to be the flow, and
  let the prose's step numbers follow them.
- **No angle brackets in a label.** `<branch>` inside a quoted label is eaten as an HTML
  tag. Describe the shape in words, and keep the literal path in the prose underneath.

## Run `domain-modeling` when you finish a feature

Not while building — when the work is done and green. Ask two questions:

- **Did the vocabulary move?** New concept, sharpened boundary, a term that turned out to
  mean two things. Update `CONTEXT.md` then and there.
- **Did a decision crystallise?** If it clears the three-part bar above, write the ADR.

A feature that changed neither is a normal outcome. Say so in one line rather than
inventing something to record.

## Run `lesson-learned` after each piece of development or refactoring

Same trigger point: work finished, tests green. Run it against the commits you just made.
The output is for the human — surface it, don't bury it in a summary.

## Both are wired to a push hook

`.claude/hooks/post-push-reflect.sh` fires on `PostToolUse` after a successful `git push`
and asks the session to run both skills on what was just pushed. It fires at most once
per pushed commit, so repeated pushes of the same work stay quiet.

A hook cannot invoke a skill — it only injects the reminder. Treat that reminder as the
standing rule it restates, not as an optional prompt. If both skills turn up nothing,
say so in one line; never skip them silently.

The hook fires *after* the push, deliberately. Blocking a push to write documentation
would be the wrong trade, and both skills are reflective — they read what landed.

## Finish

checks: mix test, mix format --check-formatted
specs: CONTEXT.md, docs/adr/, docs/architecture/, specs/spec.md

## Inherited, not repeated here

The global `CLAUDE.md` still applies in full: TDD is mandatory (failing test first),
never claim "done" without running it, and use the gate for pushing committed work where
one is set up. Nothing in this file overrides those.

The worktree protocol is no longer among them. It is the block below, written by
`whiska init` (ADR-0045) — this repo runs on the same block it ships.
