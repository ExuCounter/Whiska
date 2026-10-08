# Every task goes to a worktree; only the person saying "work in place" skips it

Every task goes to a mouse, whatever its size. The one way to skip the spawn is the
person saying to work in place. A session's own read that a task is a tweak or a quick
fix is not that, and neither is a ticket that calls the task small. Outside a herdr
session nothing changes: the work happens in the current checkout. This follows
ADR-0063 and ADR-0075 and removes the size exception each once carried.

## Why

The main session's rules sent "a real feature or fix — several files, or more than a few
minutes" to a mouse, and said to "skip the spawn for a tweak or quick fix". The session
judged "quick" alone. In the new-linkedin-plugin repo a session given a Jira ticket
called it a quick fix. It skipped the worktree and the grilling, then wrote code in the
main checkout, on an unrelated branch, with no plan and no ok.

## The rule

Three other size exceptions go with it:

- **The scout** (ADR-0075) is skipped for docs, or when no test can reach the change.
  Never for a tweak.
- **The spec** (ADR-0063) is written after every grilling round. Never skipped for a
  tweak or quick fix. A brief that needed no grilling still gets none.
- **The main session's plan** is given before anything the session does itself, not
  only before "non-trivial" work.

A truly trivial task, with no costly choice in it, is still not grilled (ADR-0063). That
is not a size exception: it skips questions that have no alternatives, not the worktree.
A typo still gets a mouse; the mouse just has nothing to ask.

## Alternatives

- **A harder size test**, such as a file count. Rejected. The session applies it, and the
  failure above was the session applying a size test.
- **Leave the exception and add "never for a ticket"**. Rejected. It patches one
  phrasing; the next "quick" task gets through another way.

## Consequences

- A one-line fix costs a worktree, a fresh mouse and the finish pipeline. That cost is
  the point: the person said everything goes through one.
- A person who wants it in place says so in the request, in their own words.
