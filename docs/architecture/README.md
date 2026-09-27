# Architecture

C4 diagrams for Whiska. `CONTEXT.md` is still the glossary and `docs/adr/` is still the
authority — these are a view onto both, not a third source of truth. Where a diagram and
an ADR disagree, the ADR wins.

| Level | File | Shows |
|---|---|---|
| 1 | [c4-context.md](c4-context.md) | Whiska between the person, Claude Code, herdr, git and launchd |
| 2 | [c4-containers.md](c4-containers.md) | Built against designed, as two boundaries |
| 3 | [c4-components-cli.md](c4-components-cli.md) | Inside the escript — hooks, init, mode, doctor, the delivery-side commands |
| 3 | [c4-components-owl.md](c4-components-owl.md) | Inside the owl — houses, herdr, doorstep, classification |
| — | [c4-dynamic-pretooluse.md](c4-dynamic-pretooluse.md) | One tool-call decision, end to end. **Built.** v0.0.1's plumbing — mouse identity as a marker file, a per-repo SQLite house,
worktree containment and sniff mode enforced through `PreToolUse` (ADR-0030). Then the
owl slice: the owl supervisor with one independently supervised house per project, each
house's herdr subscription and pane discovery, the doorstep and the `Stop` hook that
writes to it, collection on idle, and dead-mouse marking (ADR-0001, ADR-0036, ADR-0026).
Then delivery: `whiska start` recording the main session, the idle-gated queue that types
one question at a time into it, `whiska questions`, `reply` and `close`, and a newer
question superseding its mouse's earlier ones (ADR-0008, ADR-0037); `whiska mice`; and
`whiska doctor`, which checks all of the above for one repo and never repairs
(ADR-0038). 439 tests.

**Designed, decided, not yet written.** The per-repo and global sockets (ADR-0024,
ADR-0025); `launchd` supervision and `whiska stop`; push approval; `checks.yml`; the
statusline, including its "owl down" fallback (ADR-0027); cross-repo commands. The owl
runs in the foreground meanwhile, and the doctor finds it through the process table
until the global socket exists.

## Regenerating

Written by hand from `CONTEXT.md`, `docs/adr/` and `lib/`, using the `c4-architecture`
skill. The rule for keeping them honest lives in `CLAUDE.md` — when an ADR or the
built/designed split changes, the affected diagram changes in the same piece of work.
