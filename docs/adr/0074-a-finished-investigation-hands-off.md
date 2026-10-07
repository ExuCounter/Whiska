# A finished investigation hands its proposal to a fresh build mouse

A mouse's model and effort are flags to `claude`, fixed when the process starts
(ADR-0069, ADR-0073). `whiska mode build` flips a running sniff mouse to build, and the
mode is all it can flip: an investigation started on the heaviest model at the highest
effort went on to build on both. Nobody chose that, and nothing said so.

It was also the wrong price. By the time an investigation is done the work is described
and its shape is known, which is exactly what the rules in `priv/models.json` price
lowest. The right model was cheaper, and nothing picked it.

## Hand off, do not flip

- **The proposal.** A turn that investigated, changed nothing, and found something that
  should change ends its report with a **Proposed build** block — Found, Build, Touches —
  and on the done marker. `whiska-finish` teaches it. The rule is phrased by what the turn
  did, not by its mode, because a sniff mouse that never tried to write does not know it
  is one.
- **One decision, where one already is.** The finished picker in `whiska-delivered`
  (ADR-0009's `done` line) gains the option. For a proposal from a branch with nothing to
  merge — a sniff mouse's, or any mouse's whose branch has nothing on it — it holds
  Build what it proposes, Chat further, Drop it. Merge and open a request drop out: such a
  branch has nothing on it, and AskUserQuestion holds four options at most.
- **The spawn shapes from the proposal.** On yes, the main session follows
  `spawn-worktree`'s hand-off section: a branch named for what the Build line describes,
  mode, model and effort judged against the Build and Touches lines by the ordered rules
  (ADR-0073), the brief typed as one line, and a one-line report quoting what
  `whiska shape` recorded.

## Ask about intent, never about mechanics

The person settled this, and it is why the flow asks exactly once.

- The model, the effort and the branch name are derived and shown, never asked. Each is
  reversible in a sentence, and being wrong costs money or quality, not a wrong feature.
- The proposal can be wrong, so that one confirmation stays — and it carries enough to say
  no to. The option's preview is the Found, Build and Touches lines verbatim. A
  confirmation nobody reads is worse than none: it looks like oversight and provides none.
- For the same reason no option carries "(Recommended)", whatever `## Finish` names. The
  question is whether the proposal is right, and only the person's read of it can say.
- No other question anywhere in the flow. The failure being guarded against is a system
  that asks so many small questions the person stops reading them.

## The proposal travels inside the message

ADR-0009 classifies a turn by its marker alone, and the doorstep already carries the whole
message as the question's text. A second marker, or a field the `Stop` hook cut out of the
text, would be Whiska reading prose to decide something, which ADR-0009 and ADR-0017
refuse. So the proposal is content, read by the main session's Claude the way lettered
options already are. Two things make it actionable without a contract in code:

- **Fixed labels**, so the main session lifts the block verbatim into the preview instead
  of summarising it.
- **Whiska's record of the mode, and of the branch.** `whiska questions <id>` heads a
  sniff mouse's question `feat/x (sniff)`, and under any finished question's heading
  prints what its branch holds — `On the branch: nothing committed beyond main ·
  nothing uncommitted`. The picker reads those, not the mouse's word about itself, to
  know the branch has nothing to merge.

The new mouse is given the question id and nothing else; it reads the whole report with
`whiska questions <id>`, which works from any worktree, and the report stays in the house
(ADR-0007). No character a mouse wrote goes on the main session's command line: the
prompt carries only the id, and the branch is a name the main session makes out of
`a-z0-9`, `-` and `/`, never copied from the proposal. Pasting the Build line into a
quoted prompt, as first written, left one missed escape between a mouse's text and the
person's shell.

## `whiska mode` gives a mode, never changes one

*Rewritten 2026-10-06.* This section first kept the in-place flip and made it say what
it carried: "feat/x is now a build mouse. It keeps opus at xhigh effort, chosen when it
was shaped as sniff". Saying so did not fix it. The flip still left a build mouse on the
model and effort priced for an investigation, and a person had to read a line to learn
it. One mode per mouse removes the flip instead.

- `whiska mode build|sniff` gives a mode only to a mouse nobody shaped: a spawn that
  skipped the step, an older skill copy, a hand-made worktree (ADR-0069). It stamps
  `shaped_at`, so the mouse is shaped from then on.
- On a mouse that has a shape, it refuses, exits 1 and changes nothing. It says the mouse
  keeps its mode, and points to a **Proposed build** and a fresh mouse shaped for the
  build, the road this ADR describes.
- `whiska mode` with no argument still prints the mode.
- `whiska shape` records `shaped_as`, the mode the model and effort were chosen with.
  `whiska mode` no longer moves `mode` off it; running `whiska shape` again still
  re-shapes a mouse, and is the spawn's step, not a way to flip one in place.
  `whiska mice` still shows
  `build on … (shaped as sniff)` for a mouse flipped before this, until it ends.
- The sniff denial does not tell the mouse to ask the person for `whiska mode build`,
  the road to the flip nobody meant. It tells the mouse to finish with a proposal.

What the person gives up: a small fix made by the investigating session, which already
holds the context. They ask for the build, and a fresh mouse reads the proposal instead.

## Consequences

- Migration 9 adds `shaped_as`. A mouse recorded before it reads as shaped as nothing, and
  is never flagged: what it was shaped as is not known, and a guess would be a claim.
- A build mouse, or one nobody shaped (ADR-0069), that changed nothing and wrote a
  proposal is offered the build too: its heading carries no `(sniff)`, but its branch line
  says nothing is on it. One with commits or uncommitted files on its branch is
  offered what fits those instead, and the proposal goes unoffered — it changed something,
  which a proposal says it did not.
- Dropping an investigation's branch is confirmed only when the branch has commits of its
  own or files not committed — a mouse flipped from build to sniff before this change can have some. Otherwise
  nothing is lost, and the flow stays at one question.
- A repo with older skills offers no build option until `whiska init` (or
  `whiska init --global`) is re-run.
- The investigation's worktree is left standing after the hand-off: the person may still
  want to talk to it.

## Revised 2026-10-06: the picker reads the branch, not only the mode

`(sniff)` stood in for "nothing to merge" because Whiska had no record of what a branch
held. It now has one: `whiska show` prints it under every finished question's heading
(ADR-0009's note of this date). Every task goes to a mouse (ADR-0078), so a build mouse is
often the one asked to investigate, and its proposal sat behind Land here and a PR for a
branch with nothing on it. The proposal picker is offered when the heading says `(sniff)`
**or** the branch line is exactly the one for a branch with nothing on it, committed or
not; a sniff mouse behaves exactly as before. The whole line, not a phrase in it: a file
name is printed on that line too, and one named "nothing committed beyond main" must not
route a branch with commits away from Land here.
