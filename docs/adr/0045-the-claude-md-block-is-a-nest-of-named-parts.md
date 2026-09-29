# The CLAUDE.md block is a nest of named parts, and a part can be claimed

ADR-0017 said `whiska init` "writes a marked block into the project's own `CLAUDE.md`,
and `whiska update` replaces exactly that block and nothing else". One block, replaced
whole. That is enough while the block says one thing. It is not enough now that it says
three: how a mouse gets spawned, what marker it ends a turn with, and how its question
reaches the person. Those change at different times and for different reasons, and a
person may well want to keep Whiska's wording for two of them and their own for the
third.

So the block is a nest. One outer pair bounds everything Whiska will touch at all, and
inside it each part carries its own named pair:

```markdown
<!-- whiska:start -->
<!-- whiska:worktrees:start -->
…
<!-- whiska:worktrees:end -->

<!-- whiska:marker:start -->
…
<!-- whiska:marker:end -->

<!-- whiska:delivery:start -->
…
<!-- whiska:delivery:end -->

<!-- whiska:report:start -->
…
<!-- whiska:report:end -->
<!-- whiska:end -->
```

The grammar, exactly:

- A marker is a whole line of its own. `<!-- whiska:<name>:start -->` and
  `<!-- whiska:<name>:end -->`, where `<name>` is lowercase letters and hyphens. A
  sentence of prose that happens to mention one is never mistaken for one.
- A start marker may carry one word: `<!-- whiska:<name>:start keep -->`. That part is
  the person's from then on, and `init` reads straight past it without looking inside.
- The outer `<!-- whiska:start -->` … `<!-- whiska:end -->` pair bounds the region. Only
  the first pair in the file counts.

`init` then does exactly this, and is idempotent at each step:

- Text outside the outer markers comes back byte for byte. So does text the person has
  written *between* parts, inside the block.
- A part whose markers are present is replaced where it stands, keeping the order the
  file has rather than the order Whiska ships.
- A part whose markers are absent is added at the end of the block.
- A part marked `keep` is left exactly alone — content and marker both.
- A part from an older Whiska that is no longer shipped is left exactly where it is,
  not tidied away.
- No `CLAUDE.md` at all: one is created holding just the block. One that exists keeps
  everything it says and gains the block on the end.

## Why `keep` rather than deleting the markers

"A person can drop a part" and "init adds parts that are missing" are the same sentence
read two ways, and without a third thing they contradict each other: delete the part,
and the next `init` puts it back. `keep` is that third thing. Dropping a part means
emptying it and marking it `keep`, which reads as a decision in the file itself rather
than as an absence somebody has to remember the reason for. The same word covers the
other case — a part reworded to suit the repo — with no second mechanism.

The alternative was a config file listing which parts to write. Rejected: the file
would then disagree with the `CLAUDE.md` it describes, and a person editing the
`CLAUDE.md` in front of them would have no way to tell that something else had an
opinion about it. The marker sits where the person is already looking.

## Consequences

`whiska init` rewrites `CLAUDE.md` on every run, unlike `.claude/hooks/review-loop.sh`,
which is written once and then never touched (ADR-0042). The two are not inconsistent:
the loop has no way to say which part of itself is the person's, and the block does.

A part's name is now load-bearing, the way the marker's spelling is (ADR-0009):
renaming `marker` to something else would make the next `init` treat the old part as
retired and append a new one beside it. Renaming a part means migrating it, not
editing a string.

ADR-0017's `whiska update` still has no implementation, and this makes it less
necessary: `init` is the idempotent one now, at the granularity of a part, so re-running
it is the update.

What the block *says* is a separate question from this grammar. The first three parts
came from a global `~/.claude/CLAUDE.md` that applied to every repo whether Whiska
was there or not, and where nothing kept the rules in step with the code that parses
them. `Whiska.ClaudeMd` now interpolates the marker's spelling from
`Whiska.Question.Marker.render/1` rather than writing it out again, so the instruction
and the parser cannot drift.

A fourth part, `report`, has since joined them: the shape a mouse's final message takes,
because that message is the only thing the person sees of the whole turn and they see it
later and somewhere else. It arrived exactly as this grammar says a part should —
appended inside the outer markers on the next `init`, the three older parts untouched —
and the delivery part handed it the "put the complete content in the response body"
bullet rather than the two saying it twice. The rest of ADR-0017's firstmate-derived
default template is still not in the block.
