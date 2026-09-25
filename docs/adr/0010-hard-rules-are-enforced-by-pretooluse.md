# Hard rules are enforced by PreToolUse, not written in CLAUDE.md

A line in `CLAUDE.md` is a suggestion — it works only if the mouse chooses to follow it.
For rules that must never be broken, Whiska uses a `PreToolUse` hook, which runs before a
tool call and can actually block it. The same reasoning is applied consistently: "never
tear down unlanded work" is written as a principle *and* enforced mechanically by
`whiska cleanup` checking the branch is merged, because a real check beats trusting a
skill to remember.

## Consequences

The split is deliberate and load-bearing: `CLAUDE.md` carries everything that needs
judgment (see ADR-0017), and `PreToolUse` carries the short list of things that must
hold regardless of what any model decides.
