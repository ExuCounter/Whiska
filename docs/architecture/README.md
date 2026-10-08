# Architecture

C4 diagrams for Whiska: a view onto `CONTEXT.md` and `docs/adr/`, never a third source of
truth. Where a diagram and an ADR disagree, the ADR wins.

| Level | File | Shows |
|---|---|---|
| 1 | [c4-context.md](c4-context.md) | Whiska between the person, Claude Code, herdr, git and the service manager |
| 2 | [c4-containers.md](c4-containers.md) | Every process, socket and file, built against designed |
| — | [c4-dynamic-pretooluse.md](c4-dynamic-pretooluse.md) | One tool-call decision, end to end |
| — | [c4-dynamic-question-delivery.md](c4-dynamic-question-delivery.md) | A question from the doorstep to its answer |
| — | [c4-deployment.md](c4-deployment.md) | Where each piece sits on one machine |

What is built and what is still designed is the two boundaries of the container diagram
and the list in [`docs/internals.md`](../internals.md#what-is-built-and-what-is-not).
Module-level structure is `lib/` itself.

## Mermaid traps already hit

- `C4Dynamic` numbers its own relationships, in declaration order, so a `"1. "` in a `Rel`
  label renders as `1. 1.`. Order the `Rel` lines to be the flow and let the prose's step
  numbers follow them.
- An angle bracket in a label is eaten as an HTML tag: `<branch>` inside a quoted label
  vanishes. Describe the shape in words and keep the literal path in the prose.

Written by hand from `CONTEXT.md`, `docs/adr/` and `lib/`, with the `c4-architecture`
skill. `CLAUDE.md` says when a diagram must move.
