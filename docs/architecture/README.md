# Architecture

C4 diagrams for Whiska. `CONTEXT.md` is still the glossary and `docs/adr/` is still the
authority — these are a view onto both, not a third source of truth. Where a diagram and
an ADR disagree, the ADR wins.

| Level | File | Shows |
|---|---|---|
| 1 | [c4-context.md](c4-context.md) | Whiska between the person, Claude Code, herdr, git and launchd |
| 2 | [c4-containers.md](c4-containers.md) | Built against designed, as two boundaries |
| 3 | [c4-components-cli.md](c4-components-cli.md) | Inside the escript — hooks, init, mode, questions, the statusline |
| 3 | [c4-components-owl.md](c4-components-owl.md) | Inside the owl — houses, herdr, doorstep, classification |
| — | [c4-dynamic-pretooluse.md](c4-dynamic-pretooluse.md) | One tool-call decision, end to end. **Built.** |
| — | [c4-dynamic-question-delivery.md](c4-dynamic-question-delivery.md) | Doorstep → collection → delivery. **Half built.** |
| 4 | [c4-deployment.md](c4-deployment.md) | One machine: panes, files, and the sockets to come |

## The one line to carry away

Whiska owns **identity, rules and routing**. It does not own terminals or Claude Code
processes — herdr does, and is unchanged by this project (ADR-0020). Judgment belongs to
the mouse and to the person; Whiska stays dumb (ADR-0009, ADR-0017).

## Built versus designed

**Built.** v0.0.1's plumbing — mouse identity as a marker file, a per-repo SQLite house,
worktree containment and sniff mode enforced through `PreToolUse` (ADR-0030). Then the
owl slice: the owl supervisor with one independently supervised house per project, each
house's herdr subscription and pane discovery, the doorstep and the `Stop` hook that
writes to it, collection on idle, and dead-mouse marking (ADR-0001, ADR-0036, ADR-0026). Then `whiska questions` and the
project statusline `whiska init` installs, both reading one summary of the house — open
and sent questions, orphaned ones apart, and what is still on the doorstep — with the
`/whiska-questions` slash command beside them (ADR-0027, ADR-0022). 423 tests.

**Designed, decided, not yet written.** Delivery to the main session and its idle gate
(ADR-0008); the per-repo and global sockets (ADR-0024, ADR-0025); `launchd` supervision
and `whiska start`/`stop`; push approval; `checks.yml`; the statusline's mouse count and
one-mouse excerpt, and its "elsewhere" segment over the global socket; cross-repo
commands. The owl runs in the foreground meanwhile.

## Regenerating

Written by hand from `CONTEXT.md`, `docs/adr/` and `lib/`, using the `c4-architecture`
skill. The rule for keeping them honest lives in `CLAUDE.md` — when an ADR or the
built/designed split changes, the affected diagram changes in the same piece of work.
