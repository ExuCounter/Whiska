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
  (ADR-0009's `done` line) gains the option. For a sniff mouse with a proposal it holds
  Build what it proposes, Chat further, Drop it. Merge and open a request drop out: a
  sniff branch has nothing on it, and AskUserQuestion holds four options at most.
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
- **Whiska's record of the mode.** `whiska questions <id>` heads a sniff mouse's question
  `feat/x (sniff)`. The picker reads that, not the mouse's word about itself, to know the
  branch has nothing to merge.

The new mouse is given the question id and nothing else; it reads the whole report with
`whiska questions <id>`, which works from any worktree, and the report stays in the house
(ADR-0007). No character a mouse wrote goes on the main session's command line: the
prompt carries only the id, and the branch is a name the main session makes out of
`a-z0-9`, `-` and `/`, never copied from the proposal. Pasting the Build line into a
quoted prompt, as first written, left one missed escape between a mouse's text and the
person's shell.

## `whiska mode` stays, and says what it carried

Refusing the flip was rejected. `whiska mode` is also how a mouse nobody shaped gets its
mode (ADR-0069), and a person who wants a small fix made by the session that already holds
the context can still choose that. What made the flip wrong was that it was silent.

- `whiska shape` records `shaped_as`, the mode the model and effort were chosen with.
  `whiska mode` moves `mode` and leaves `shaped_as` alone.
- A flip off the shape says what it carried: "feat/x is now a build mouse. It keeps opus
  at xhigh effort, chosen when it was shaped as sniff". `whiska mice` shows
  `build on … (shaped as sniff)` for as long as it runs.
- The sniff denial stopped telling the mouse to ask the person for `whiska mode build`,
  which was the road to the flip nobody meant: a mouse denied an edit asked to be
  flipped, and was. It now tells the mouse to finish with a proposal.

## Consequences

- Migration 9 adds `shaped_as`. A mouse recorded before it reads as shaped as nothing, and
  is never flagged: what it was shaped as is not known, and a guess would be a claim.
- A build mouse that writes a proposal gets the four options, and the proposal goes
  unoffered. So does a mouse nobody shaped (ADR-0069): its heading carries no `(sniff)`,
  though it could not write either. Both were shaped wrong to begin with, and the person
  can still talk to them.
- Dropping an investigation's branch is confirmed only when the branch has commits of its
  own — a mouse moved from build to sniff can have some. Otherwise nothing is lost, and
  the flow stays at one question.
- A repo with older skills offers no build option until `whiska init` (or
  `whiska init --global`) is re-run.
- The investigation's worktree is left standing after the hand-off: the person may still
  want to talk to it.
