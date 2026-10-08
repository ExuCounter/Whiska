# Whiska

An Elixir/OTP coordinator for Claude Code sessions working in isolated git worktrees.
Replaces this dotfiles setup's bash worktree-notification relay.

The design is written down. `CONTEXT.md` is the glossary, the canonical name for every
concept; `docs/adr/README.md` indexes every decision by area, one file each. Before a
change, read the glossary entries for what you touch and the ADRs the index lists under
that area. `CONTEXT.md` and the ADRs are the authority.

## ADRs are binding

**Cite the ADR** whenever a design or implementation choice is one an ADR already covers —
"per ADR-0011, the hook denies immediately rather than waiting". The citation is how the
next reader knows the choice was inherited rather than invented on the spot.

**Contradict an ADR only out loud.** When the right thing now conflicts with a recorded
decision — or the code you are about to write quietly does something else — stop before
writing it and give exactly this, in one message:

1. Which ADR, by number and title.
2. What it currently says, quoted.
3. What you want to do instead, and why the ADR's reasoning does not hold here.
4. **What behaviour actually changes** if we go your way — the user-visible consequence,
   not just the code shape.
5. Your recommendation.

Then wait. The user decides whether the attempt is right; this is not a rubber stamp. An
ADR being wrong is a normal outcome — the point is that it changes deliberately, in the
file, rather than drifting out of date while the code walks away from it.

A changed decision changes its ADR in the same piece of work: supersede it or rewrite it,
and update `docs/adr/README.md`. A stale ADR is worse than none.

**A new ADR** needs all three, or skip it: hard to reverse, surprising without context,
and the result of a real trade-off with genuine alternatives. Name it
`docs/adr/next-<slug>.md` and cite it as `ADR-` then `next-<slug>`. Leave the number
unpicked: it is only known when the branch lands.

**Before merging a branch whose `docs/adr/` holds a `next-` file**, run `mix adr.claim` in
its worktree and commit the result on the branch, then merge. `mix test` fails on a
placeholder that reached main, a number taken twice, or a citation with no record behind
it.

## Use the repo's words

`CONTEXT.md` is the glossary — Whiska, mouse, `mouse_id`, question, house, owl, build
mode, sniff mode. Use those names in code, comments, commit messages and between
sessions. In a message to the person, use one only after they have; otherwise say what
the thing does. Use the glossary's own name for each concept: no synonyms, and none of the
`_Avoid_` words listed under each term — each was rejected for a reason.

## Keep the architecture diagrams honest

`docs/architecture/` holds C4 diagrams: a view onto the ADRs, never a third source of
truth. Where they disagree, the ADR wins and the diagram is what is wrong. When a
container, a stored thing, a boundary, a documented flow or the built-and-designed split
moves, the diagram moves in the same piece of work; a change that moves none of those is
a normal outcome, said in one line. Its README lists the Mermaid traps already hit.

## When a piece of work is done and green

Not while building — once the work is finished and its tests pass, run each skill below
at its own trigger, against what just landed. Each turning up nothing is a normal outcome:
say so in one line, never skip it silently.

- **`domain-modeling`**, after a feature. Did the vocabulary move — a new concept, a
  sharpened boundary, a term that turned out to mean two things? Update `CONTEXT.md` then
  and there. Did a decision crystallise that clears the three-part bar above? Write the
  ADR.
- **`lesson-learned`**, after each piece of development or refactoring, against the
  commits just made. Its output is for the human: surface it rather than bury it in a
  summary.

`.claude/hooks/post-push-reflect.sh` fires on `PostToolUse` after a successful `git push`,
at most once per pushed commit, and asks the session to run both on what was pushed. A
hook cannot invoke a skill — it only injects the reminder. Treat that reminder as this
standing rule, not an optional prompt. It fires after the push on purpose: blocking a push
to write documentation would be the wrong trade, and both skills read what landed.

## Finish

checks: mix test, mix format --check-formatted
specs: CONTEXT.md, docs/adr/, docs/architecture/

## Inherited, not repeated here

The global `CLAUDE.md` still applies in full: TDD is mandatory (failing test first), never
claim "done" without running it, and push committed work through the gate where one is
set up. Nothing in this file overrides those.

The worktree protocol comes from the global install `whiska init --global` writes
(ADR-0056): a `SessionStart` hook prints each session's rules by role (ADR-0081). This
repo keeps no local install, so the copy in force here is the one every other repo on
this machine gets.
