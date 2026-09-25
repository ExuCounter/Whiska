# The per-repo slice is a "house" and the machine-wide process is an "owl"

These were first called "subtree" and "daemon". Both were renamed deliberately, and this
record exists mainly so nobody helpfully renames them back.

"Subtree" is unusable in this project specifically: it already means a git subtree, in a
tool that is entirely about git worktrees, *and* an OTP supervision subtree, in an
Elixir/OTP codebase where the thing in question is literally implemented as one. Two
live collisions in the exact two domains this code sits in. "House" carries the same
meaning — one project's own isolated place — with no collision.

"Daemon" is accurate but generic, and it described the process by its supervision
mechanism rather than by its role. "Owl" names the role instead: the one always-awake
presence per machine, the only thing that can see across every house at once. It also
keeps the vocabulary coherent with Whiska and mice, which were already named this way.

See `CONTEXT.md` for the current definitions; it is the source of truth for the language.
