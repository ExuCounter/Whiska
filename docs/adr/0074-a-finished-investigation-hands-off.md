# A finished investigation hands its proposal to a fresh build mouse

A turn that investigated, changed nothing, and found something that should change ends
its report with a **Proposed build** block and on the done marker. The person is offered
Build what it proposes or Not now, and on yes the main session spawns a fresh mouse
shaped for that build. A mouse's mode is never flipped in place: `whiska mode` gives a
mode only to a mouse nobody shaped and refuses a shaped one.

## Why a hand-off, not a flip

A mouse's model and effort are flags to `claude`, fixed when the process starts
(ADR-0069). Flipping a running sniff mouse to build flipped the mode and nothing else, so
an investigation started on the heaviest model at the highest effort went on to build on
both. Nobody chose that, and nothing said so. It was also the wrong price: by the time an
investigation is done the work is described and its shape is known, which is what the
rules in `priv/models.json` price lowest. Saying what the flip carried ("it keeps opus at
xhigh effort, chosen when it was shaped as sniff") did not fix it; one mode per mouse
removes the flip.

## The rule

- **The proposal.** The block is Found, Build and Touches lines. `whiska-finish` teaches
  it. The rule is phrased by what the turn did, not by its mode, because a sniff mouse
  that never tried to write does not know it is one.
- **One decision, where one already is.** The finish options in `whiska-delivered`
  (ADR-0009's `done` line) offer Build what it proposes and Not now when the branch has
  nothing to merge: the question's heading says `(sniff)`, or its branch line is exactly
  the one for a branch with nothing on it, committed or not. Merge and open a request
  drop out, since such a branch has nothing on it. The person's notes go as free text,
  carried to the mouse from the main session.
- **The spawn shapes from the proposal.** On yes the main session follows
  `spawn-worktree`'s hand-off section: a branch named for what the Build line describes,
  mode, model and effort judged against the Build and Touches lines by the ordered rules
  (ADR-0069), the brief typed as one line, and a one-line report quoting what `whiska
  shape` recorded.
- **`whiska mode build|sniff` gives a mode only to a mouse nobody shaped**: a spawn that
  skipped the step, an older skill copy, a hand-made worktree (ADR-0069). It stamps
  `shaped_at`. On a mouse that has a shape it refuses, exits 1, changes nothing, and
  points to a Proposed build and a fresh mouse. `whiska mode` with no argument prints
  the mode. `whiska shape` records `shaped_as`, the mode the model and effort were chosen
  with; `whiska mice` shows `build on … (shaped as sniff)` for a mouse flipped before this
  rule, until it ends.

## Ask about intent, never about mechanics

The flow asks exactly once. The model, the effort and the branch name are derived and
shown, never asked: each is reversible in a sentence, and being wrong costs money or
quality, not a wrong feature. The proposal can be wrong, so that one confirmation stays,
and it carries enough to say no to: the Found, Build and Touches lines are shown verbatim
just above the lettered options (ADR-0022). No option carries "(Recommended)", whatever
`## Finish` names; only the person's read of the proposal can say whether it is right.
The failure guarded against is a system that asks so many small questions the person
stops reading them.

## The proposal travels inside the message

ADR-0009 classifies a turn by its marker alone, and the doorstep already carries the whole
message as the question's text. A second marker, or a field the `Stop` hook cut out of
the text, would be Whiska reading prose to decide something, which ADR-0009 and ADR-0081
refuse. So the proposal is content, read by the main session's Claude the way lettered
options are. Two things make it actionable without a contract in code: fixed labels, so
the main session shows the block verbatim instead of summarising it; and Whiska's own
record of the mode and the branch. `whiska questions <id>` heads a sniff mouse's question
`feat/x (sniff)` and prints what any finished question's branch holds under its heading.
The options read those, not the mouse's word about itself. The whole branch line is
matched, not a phrase in it: a file named "nothing committed beyond main" must not route
a branch with commits away from Land here.

The new mouse is given the question id and nothing else; it reads the whole report with
`whiska questions <id>`, and the report stays in the house (ADR-0007). No character a
mouse wrote goes on the main session's command line: the prompt carries only the id, and
the branch is a name the main session makes out of `a-z0-9`, `-` and `/`, never copied
from the proposal. Pasting the Build line into a quoted prompt left one missed escape
between a mouse's text and the person's shell.

## Considered options

- **Flip the sniff mouse to build in place.** Keeps the context, but keeps the model and
  effort priced for an investigation, and a person had to read a line to learn it.
- **Chat further and Drop it as options.** Nobody picked Drop on an investigation, and
  Chat further moved the person out of the session they run everything from.
- **Offer the build only when the heading says `(sniff)`.** Every task goes to a mouse
  (ADR-0078), so a build mouse is often the one asked to investigate, and its proposal
  sat behind Land here for a branch with nothing on it. The branch line settles it.

## Consequences

- The mice table carries `shaped_as`. A mouse recorded before it reads as shaped as
  nothing and is never flagged; a guess would be a claim.
- A build mouse, or one nobody shaped, that changed nothing and wrote a proposal is
  offered the build too. One with commits or uncommitted files on its branch is offered
  what fits those, and the proposal goes unoffered: it changed something, which a
  proposal says it did not.
- Dropping an investigation's branch is confirmed only when the branch has commits of
  its own or files not committed. Otherwise nothing is lost, and the flow stays at one
  question.
- The investigation's worktree is left standing after the hand-off: the person may still
  want to talk to it.
- What the person gives up: a small fix made by the investigating session, which already
  holds the context. They ask for the build, and a fresh mouse reads the proposal.
- A repo with older skills offers no build option until `whiska init`, or `whiska init
  --global`, is re-run.
