# The block is rules, not prose, and the finish pipeline ships as a skill

The block `whiska init` writes grew by accretion. Every decision that landed in it —
ADR-0009's marker, ADR-0045's parts, ADR-0049's pipeline, ADR-0054's roster — arrived as
the paragraph that explained it, because each was written while the reasoning was still
live. By five parts that was around 3,300 words of prose in every repo's `CLAUDE.md`, read
by every session there on every turn, most of it motivation for rules the session was
going to follow either way.

Two changes, together worth about two thirds of it.

## The block is rules

Each part is a short lead paragraph saying who the rules bind and when, then one bullet
per rule. A line earns its place by being an imperative or a concrete fact — a command, a
path, a marker spelling. Rationale is cut.

The exception is a rule a session would misapply without knowing why, and it is narrow
enough to name in place: a reason stays when deleting it changes behaviour. "Never
`herdr agent prompt` into the pane" keeps "only `whiska reply` frees the one delivery
slot", because a session that does not know about the slot will reach for the pane the
moment it looks faster. "Read the file under `.claude/agents/`" keeps "not the session's
listing of it", because the listing is the obvious thing to read and reading it satisfies
nothing.

## The finish pipeline ships as a skill

ADR-0049's five steps were 1,900 of those words — 58% of the block — and they are the one
part that matters at a single moment, when a turn is about to end on the done marker.
Carrying them on every turn bought nothing. They are now
`.claude/skills/whiska-finish/SKILL.md`, installed by `init` beside the worktree skills
and read at compile time from `priv/skills/`, exactly as ADR-0046 does it. The block
keeps the trigger, which is the part that has to be in context: before the done marker,
run `whiska-finish`.

The block's pointer names the file as well as the skill, because a repo that has not
committed `.claude/skills/` has the rules on disk but nothing listing them.

The marker's spelling is interpolated into the block from `Whiska.Question.Marker`
(ADR-0045) and cannot be, in a static skill file. A test pins the skill's spelling against
`Marker.spell/1` instead, which is the same guarantee by a slower route.

## How a session talks is part of the report part, not a config file

The person's rules for how a session talks to them — concise, plain language, lead with
the answer, show the change rather than describe it, never repeat their words back — are
folded into the `report` part rather than given a file of their own. They overlap the
report shape almost entirely: "lead with the answer" is already "what is true now, one
line", and "mention only what matters" is already the leave-out list. Merged, they cost
six lines; as a separate mechanism they would cost a config file Whiska does not have.

There is no `~/.whiska` config today, and inventing one to hold six lines of style would
put the rules somewhere the session cannot see them without Whiska reading the file and
writing it into the block anyway. The block is already the thing `init` writes into every
repo, so the block is already "from Whiska, everywhere". A repo that wants its own voice
puts `keep` on the `report` part, which is the mechanism ADR-0045 already provides.

Two of the rules conflicted with how a mouse already works, and both were settled rather
than merged silently. A grilling round still asks the whole frontier in one message —
"ask one question, don't guess" governs ordinary mid-work ambiguity, because each grilling
round costs the person a full round trip. And the 2–4 line plan that waits for an ok binds
the main session only: a mouse builds and stops on a real decision, which is what keeps
the person's terminal free.

The cost: these are one person's preferences shipped in a tool's default text. They are
mild enough to read as good practice rather than idiosyncrasy, and `keep` is the exit.

## Why not keep the prose

Prose costs context where context is what a session has instead of memory, and a rule
buried in a paragraph is a rule that gets skimmed. Against that: rationale is what keeps a
rule from being applied wrongly at the edges, and what lets a person decide the rule no
longer fits. Both still exist, in `docs/adr/`, where they were extracted to in the first
place. A consuming repo does not have Whiska's ADRs, so the block carries no pointer to
them; it carries only what its reader has to do. Somebody asking *why* is asking Whiska,
not their own `CLAUDE.md`.

The alternative to a skill was a second marked block, or a plain file the block points at.
A skill is the one shape Claude Code already loads on demand and lists to the session, and
`init` already ships four of them.

## Consequences

Every future edit is held to the same bar: a new rule arrives as a bullet, its reasoning
arrives as an ADR, and a rule that only applies at one moment arrives as a skill rather
than as block text.

`Whiska.ClaudeMd`'s tests pin behaviour rather than sentences — that each rule is present,
and that the facts a session acts on are exact — plus a ceiling on the block's length, so
the next accretion fails a test rather than landing quietly. `whiska-finish` is pinned the
same way in `Whiska.InstallFinishSkillTest`.

The parts and their grammar are untouched: ADR-0045 still describes what `init` writes and
how it merges, and a person's `keep` on the finish part keeps their old copy — pipeline
and all — through this rewrite, which is the mechanism working, not a migration gap.

ADR-0049 and ADR-0054 are unchanged in substance. Where they say "the block", the steps
they describe now live in the skill the block points at.

ADR-0063 narrows one sentence of this one: a mouse sends no plan, but it does wait for an
ok on its costly choices, and "it builds, and stops only on a real decision" does not
cancel that. The block says so in that bullet.
