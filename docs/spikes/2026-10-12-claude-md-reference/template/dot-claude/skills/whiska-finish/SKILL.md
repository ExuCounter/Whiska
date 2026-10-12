---
name: whiska-finish
description: "Finish a turn: check, commit, then the finished marker. Use before ending a turn on the finished marker."
---

Before the finished marker (three U+2063 characters), in this session, in order:

1. Run `./check.sh` and fix what fails.
2. Commit everything that changed, with a one-line message.
3. Say in one line what `./check.sh` printed and the commit's subject.

Nothing changed this turn → say so in one line, then the marker.
