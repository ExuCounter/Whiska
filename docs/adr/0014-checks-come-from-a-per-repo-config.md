# Whiska runs no checks of its own

**Superseded on 2026-09-28 by [ADR-0042](0042-the-review-loop-is-a-stop-hook-the-repo-owns.md).**
What this decision said before:

> "Is this worktree actually done?" is not answered by asking the mouse — a mouse marking
> itself `done` is just its own opinion. What decides is whether a small set of repo-defined
> checks pass. Those checks live in `.whiska/checks.yml`, scaffolded by `whiska init`: a
> flat list of named shell commands (`test: mix test`, `lint: mix credo`). The person writes
> it, the same way they write the `CLAUDE.md` block. No-mistakes, a bare `npm test`, a
> Makefile target — each is one line, and none of it is hardcoded into Whiska.
>
> An empty or missing file means no checks configured: Whiska does only its edit/push
> enforcement and nothing more. All configured checks run in parallel, since they are
> independent commands with no ordering dependency. Whiska reports exactly which ones
> failed, with their output, not a pass/fail blob. If a real automated review tool is
> adopted later, it slots in as one more line and Whiska stays exactly as dumb as it is
> today.

**Whiska now runs no checks at all.** There is no `checks.yml`, no runner, and no check
step anywhere in push approval. What decides whether a worktree is actually done is the
repo's own `Stop` hook (ADR-0042), a shell script under `.claude/hooks/` with the check
command written at the top of it.

## Why

`checks.yml` was never built, which is the cheap half of the reason. The real half is that
it was a second place to say a thing the repo already says. A repo that runs `mix test`
says so in its `CLAUDE.md`, in its own scripts, in whatever gate it pushes through. Adding
`.whiska/checks.yml` beside those means the answer to "how is this repo checked" depends on
which file you opened, and Whiska becomes something you configure rather than something
that routes messages.

It also pulled Whiska across the line ADR-0017 draws. Running a check is mechanical, so it
does not break "Whiska stays dumb" on its own — but *deciding* a check list, owning its
schema, parallelising it and reporting which of them failed is a configuration surface with
opinions in it, and every future demand ("run these only on push", "this one is advisory")
lands on Whiska rather than on the repo.

The timing was the last of it. Checks belong at the end of a *turn*, where a failure is
still cheap to fix, not at push, where the mouse has already committed and moved on.
A `Stop` hook is at the end of a turn by construction.

## Consequences

**ADR-0011 loses its check step.** It said the push flow was "checks, then approval, then
the real push"; push approval now carries the diff alone. Its bounded-escalation shape
survives, borrowed by ADR-0042 for the same reason it existed: a loop that cannot end is
worse than a failure you can see.

**ADR-0015 stands, and gets slightly weaker honestly.** Its list of what protects you
without an automated reviewer named `checks.yml` as the thing that "catches anything
mechanical first". That job did not disappear — it moved to the repo's own `Stop` hook,
one layer earlier and outside Whiska.

**Nothing is deleted from the code**, because no runner was ever written. What went was
three doc mentions and the entry in the designed-but-not-built list.
