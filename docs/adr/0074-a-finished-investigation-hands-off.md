# A finished investigation hands its proposal to a fresh build mouse

A turn that investigated, changed nothing, and found something that should change ends
its report with a **Proposed build** block and on the done marker, and writes its
findings and the same block to a **research document** the person reviews line by line. The
person is offered Build what it proposes or Not now, and on yes the main session spawns
a fresh mouse shaped for that build, carrying the person's comments on the research document
when they gave some. A mouse's mode is never flipped in place: `whiska mode` gives a
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

- **The proposal.** The block is Found, Build, Touches and Open lines. `whiska-finish` teaches
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
and it carries enough to say no to: the Found, Build, Touches and Open lines are shown verbatim
just above the lettered options (ADR-0022). No option carries "(Recommended)", whatever
`## Finish` names; only the person's read of the proposal can say whether it is right.
The failure guarded against is a system that asks so many small questions the person
stops reading them.

## A **Needs attention** block works the same way

A finished turn that advises a step on its own branch before landing says so in a
**Needs attention** block (`whiska-finish` teaches it). The main session reads the label,
never the prose, and offers each item as a lettered option ahead of the options for the branch line (Land, PR and Drop, or their commit-first forms),
marking only the mouse's own recommendation "(Recommended)". No block, no items: the
fixed table stands.

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

The new mouse is given the question id, and the path of a file holding the person's
comments on the research document when they gave some; it reads the whole report with
`whiska show <id>`, and the report stays in the house (ADR-0007). No character a mouse
wrote goes on the main session's command line: the prompt carries only the id and a path
the main session chose, and the branch is a name it makes out of `a-z0-9`, `-` and `/`,
never copied from the proposal. Pasting the Build line into a quoted prompt left one
missed escape between a mouse's text and the person's shell.

## The research document

A chat message carrying a proposal can only be answered in chat. A spec is reviewed line
by line in the person's review tool, from a link (ADR-0063), and they wanted the same for
an investigation, with what they commented reaching the build.

It is one template, the `whiska-research` skill's, with sections switched on by the kind
of work: an investigation's question, findings and Proposed build, or a bug's before and
after, cause and fix options, which a bug fix is approved from before any code
(ADR-0063). It was first named the write-up, for investigations alone.

- **The mouse writes it.** Before its report, the turn writes `.whiska-research.md` at its
  worktree root: what it established, in full, then the same Proposed build block. The
  block stays in the message too, since the options read it there. With no proposal it
  writes one only when the findings outgrow the report. `whiska-finish` teaches it,
  phrased by what the turn did, like the proposal. It is the one file a sniff mouse may
  write (ADR-0069). Git ignores it through the main checkout's exclude file, which
  `whiska shape` and `whiska mode` write as they do for the spec (ADR-0063), and the owl
  writes on opening the house, so the branch still has nothing on it.
- **Whiska keeps it once per branch.** The `Stop` hook carries it on the doorstep entry
  beside the spec, with the same limits, and the owl writes it at collection beside the
  kept spec, as ADR-0063 keeps a spec: one file per branch, overwritten each round. It is
  not a spec: it never marks the
  question `spec_sent`, so the spec figures (ADR-0086) count only specs.
- **`whiska show` links it** under the branch line of a finished question, as
  `Review research here:`, by its first heading, as it links the diff (ADR-0085). The link
  is Whiska's, not the mouse's: the mouse cannot know its question id. It names the kept
  copy, so it works from a mouse's worktree too, and after the investigation's worktree
  is gone. Every question from the branch names the same copy, so a link read from an
  earlier round opens the latest text, and comments land on it. A question kept before
  this has its own copy in `.whiska/research/<id>.md`, and links that.
- **Comments are the person's words, carried in a file.** The review tool's Send makes
  the review the main session's next message. Read against the question last shown, it
  is offered three ways: build what it proposes with these comments, send them to the
  investigating mouse, or not now; with no proposal to build, or a branch with something
  on it, only the last two. The
  review quotes the research document, which a mouse wrote, so the main session writes it with
  the file tool to a file outside both checkouts, as it writes a commit message, and the
  prompt names that file. On the build, the fresh mouse's one prompt is the fixed line
  plus that path; sent to the investigating mouse, a fixed line plus that path asks it
  to recheck and rewrite its research document, and it finishes again. Nothing multi-line is
  typed into a pane, where a newline can send half (ADR-0080).

## Considered options

- **Flip the sniff mouse to build in place.** Keeps the context, but keeps the model and
  effort priced for an investigation, and a person had to read a line to learn it.
- **Chat further and Drop it as options.** Nobody picked Drop on an investigation, and
  Chat further moved the person out of the session they run everything from.
- **Offer the build only when the heading says `(sniff)`.** Every task goes to a mouse
  (ADR-0078), so a build mouse is often the one asked to investigate, and its proposal
  sat behind Land here for a branch with nothing on it. The branch line settles it.
- **Comments go only to the investigating mouse,** which rewrites its research document, and the
  build starts from the id alone. Keeps the prompt to the id, at one more round on the
  model chosen for the investigation, when the person often meant the build.
- **Whiska stores the comments on the question,** with a command for the main session to
  record them, and the build reads them by id. A new interface and stored field for text
  the person already handed the main session.
- **Type the comments into the prompt, joined into one line and quoted** as the person's
  own words are. Simpler, but the review quotes the mouse's text, so its safety rested
  on the main session escaping hostile text perfectly every time.
- **Link the worktree's own file,** as the spec does. It dies with the worktree, and the
  build may start after the person drops it.

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
- A doorstep entry carries an optional `research` field; one without it still decodes.
  The kept copy holds only the latest round; an earlier one is gone once overwritten, as
  an earlier spec is (ADR-0063).
- The owl also writes the research document's exclude line when it opens a house, as it does the
  marker's (ADR-0002), so a worktree shaped before this hides its research document too.

Changed on 2026-10-12: the research document is kept once per branch beside the kept spec,
not per question, so an earlier question's link opens the latest round (ADR-0063).
