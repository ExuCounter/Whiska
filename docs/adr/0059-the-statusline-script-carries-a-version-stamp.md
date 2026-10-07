# The statusline script carries a version stamp, and an old copy is an upgrade notice

**Superseded on 2026-10-07 by [ADR-next-a-mouses-state-is-a-line-in-herdrs-sidebar](next-a-mouses-state-is-a-line-in-herdrs-sidebar.md).**
No statusline script is written any more, so there is no copy to stamp: `whiska doctor`
names a leftover one as a warning, and `whiska init` removes it. Everything below is what
this decision said, and is history.

`whiska init` writes `.claude/hooks/whiska-statusline.sh` into the repo, and the repo keeps
it: it is committed, so everyone working there runs the same line (ADR-0016). The script
changes as the line does — it learned to print the board rather than ask for one
(ADR-0051), and to fall back to the base line the global install kept beside it when the
global `statusLine` turns out to be Whiska's own (ADR-0056).

A copy from before that last change is silent in the worst way. It blanks the global
command because the command is Whiska's own, has nowhere to fall back to, and prints no
base line at all — so the person loses their model-and-branch line, and never sees the
board that would have told them a queue was waiting. Nothing is broken enough to fail; it
simply stops drawing.

## Decision

**The script carries its own version**, a `# whiska-statusline: v<n>` line written by the
build that shipped it, bumped whenever the script changes.

**`whiska doctor` reads the repo's copy and compares the stamp**, and says
`whiska upgrade is available`, with `whiska init` as the fix. It is worded as an upgrade
notice rather than a fault, because that is what it is: the repo's copy still runs, and
there is a newer one to write.

**Nothing rewrites that file.** Not the doctor (ADR-0038), and not `whiska start` either.
The file is committed and shared with whoever else works in the repo, so editing it is a
change in their working tree at a moment nobody chose. `whiska init` is the one thing that
writes it, which is what it is for.

## Consequences

- **A repo with no copy of its own says nothing here.** The global install draws the line
  for it, and the existing `statusLine` check already reports on that.
- **The stamp is the only comparison.** Not the file's bytes: a person who edits their copy
  deliberately is not out of date, and a diff would call them out every time.
- **A copy newer than this build is reported the other way round.** Somebody else ran a
  newer `whiska init` and committed it; running this one would write the older script back
  over a shared file. The doctor says so and names the binary, not `init`.
- **An old copy is still found the moment the doctor runs**, which is also the moment the
  person is already asking what is wrong.

## Considered options

**Self-heal: rewrite an out-of-date script on `whiska start`.** Rejected by the person whose
repo it is — a surprise edit in a committed file, and a dirty working tree in a repo shared
with their team.

**Let the script heal itself.** Not available: a copy already on disk is the thing that is
old, and it cannot grow the code that would notice.

**Fail rather than warn.** Rejected: nothing is lost. Questions are still collected,
recorded and delivered; what is lost is a line being drawn, which is ADR-0038's definition
of a warning.
