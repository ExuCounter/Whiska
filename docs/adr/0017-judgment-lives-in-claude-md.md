# All judgment lives in CLAUDE.md; Whiska stays dumb

Whiska does routing and storage. It does no reasoning. Everything that requires judgment —
priority, what is worth escalating, what a mouse should and should not do — lives in
plain-English rules the mice actually read, the same way firstmate uses `AGENTS.md`. No
scoring system, no algorithm: a short list of hard rules that never bend, plus written
principles for everything else, and a capable model reading them.

`whiska init` writes a marked block into the project's own `CLAUDE.md`, and `whiska
update` replaces exactly that block and nothing else.

## Consequences

The default template is adapted from firstmate's real hard rules: never tear down unlanded
work; report outcomes faithfully; evidence-first when asking for a decision (with a
concrete four-part template, not just the principle); durable state over memory; check git
state before assuming a blank slate; use subagents freely inside your own worktree; a
finding is not a green light; investigate rigorously, not just fast; scope creep gets
surfaced rather than folded in; one approval does not carry over.

One rule in the same block aims the other way, at the main session rather than a mouse:
present a delivered question faithfully, then wait. A helpful model might run `whiska diff`
itself or guess an answer. Answering is always the human's move.

"Check git state before assuming a blank slate" being a standing habit rather than a
special case is what keeps `whiska reopen` simple — reopen just delivers the saved question
as the first message, because the git-checking behaviour is already there by default.

A persistent sub-supervisor layer (firstmate's secondmate equivalent) was researched and
rejected as overkill for one person's personal projects.
