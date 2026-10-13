# A finished investigation hands its proposal to a fresh build mouse

A turn that investigated, changed nothing, and found something that should change ends
its report with a **What to change** block and on the done marker, and writes its findings
and the same block to a **research document** the person reviews line by line. When the
person says to build it, the main session runs `whiska spawn build <branch> --from <id>`,
a fresh mouse shaped for that build, with `--comments <file>` when the person commented on
the research document. A mouse's mode is never flipped in place: `whiska mode` gives a
mode only to a mouse nobody shaped and refuses a shaped one.

## Why a hand-off, not a flip

A mouse's model and effort are flags to `claude`, fixed when the process starts
(ADR-0069). Flipping a running sniff mouse to build flipped the mode and nothing else, so
an investigation started on the heaviest model at the highest effort went on to build on
both. Nobody chose that, and nothing said so. It was also the wrong price: by the time an
investigation is done the work is described and its shape is known, which is what the
rules in `priv/models.json` price lowest. One mode per mouse removes the flip.

## The rule

- **The proposal.** The block is the label `**What to change**` and five lines: Found,
  Build, Why, Cost and Open. The sniff brief carries it, and the build brief reads it
  (ADR-next-one-brief-per-session).
- **The person asks for the build.** The main session shows the report with `whiska show`
  and stops. "Build it" is the person's to say, in their words; nothing is offered.
- **The spawn is fixed text.** `whiska spawn build <branch> --from <id>` writes the new
  mouse's task as a fixed line naming the question: read it with `whiska show <id>`, its
  Build line is the task, Found is fact, Open is what to grill, and read the research
  document it links. The main session picks the branch, mode, model and effort, judged
  against the Build line by the ordered rules (ADR-0069), and passes each as an argument.
- **`whiska mode build|sniff` gives a mode only to a mouse nobody shaped**: a hand-made
  worktree, or one from an older spawn (ADR-0069). It stamps `shaped_at`. On a mouse that
  has a shape it refuses, exits 1, changes nothing, and points to What to change and a
  fresh mouse. `whiska mode` with no argument prints the mode. `whiska shape` records
  `shaped_as`, the mode the model and effort were chosen with; `whiska mice` shows
  `build on … (shaped as sniff)` for a mouse flipped before this rule, until it ends.

## The proposal travels inside the message

ADR-0009 classifies a turn by its marker alone, and the doorstep already carries the whole
message as the question's text. A second marker, or a field the `Stop` hook cut out of
the text, would be Whiska reading prose to decide something, which ADR-0009 refuses. So
the proposal is content, read by the person and the main session. `whiska questions <id>`
heads a sniff mouse's question `feat/x (sniff)` and prints what any finished question's
branch holds under its heading.

No character a mouse wrote goes on the main session's command line: `--from` carries only
the id, `--comments` a path the main session chose, and the branch is a name it makes out
of `a-z0-9`, `-` and `/`, which `whiska spawn` refuses otherwise, never copied from the
proposal. The new mouse reads the whole report with `whiska show <id>`, and the report
stays in the house (ADR-0007).

## The research document

A chat message carrying a proposal can only be answered in chat. A spec is reviewed line
by line in the person's review tool, from a link (ADR-0063), and they wanted the same for
an investigation, with what they commented reaching the build.

It is one template, in the brief that writes it: an investigation's question, findings
and What to change in the sniff brief, or a bug's before and after, cause and fix options
in the build brief, which a bug fix is approved from before any code (ADR-0063).

- **The mouse writes it.** Before its report, the turn writes `.whiska-research.md` at its
  worktree root: what it established, in full, then the same What to change block when
  something should change. It is the one file a sniff mouse may write (ADR-0069). Git
  ignores it through the main checkout's exclude file, which `whiska shape` and
  `whiska mode` write as they do for the spec (ADR-0063), and the owl writes on opening
  the house, so the branch still has nothing on it.
- **Whiska keeps it once per branch.** The `Stop` hook carries it on the doorstep entry
  beside the spec, with the same limits, and the owl writes it at collection beside the
  kept spec, as ADR-0063 keeps a spec: one file per branch, overwritten each round. It is
  not a spec: it never marks the question `spec_sent`, so the spec figures (ADR-0086)
  count only specs.
- **`whiska show` links it** under the branch line, as `Review research here:`, by its
  first heading, as it links the diff (ADR-0085). The link is Whiska's, not the mouse's:
  the mouse cannot know its question id. It names the kept copy, so it works from a
  mouse's worktree too, and after the investigation's worktree is gone. Every question
  from the branch names the same copy, so a link read from an earlier round opens the
  latest text, and comments land on it. A question kept before this has its own copy in
  `.whiska/research/<id>.md`, and links that.
- **Comments are the person's words, carried in a file.** The review tool's Send makes
  the review the main session's next message. The review quotes the research document,
  which a mouse wrote, so the main session writes it to a file outside both checkouts.
  For the build, `--comments <file>` copies it into the new worktree and the task names
  the copy; for the investigating mouse, `whiska send <branch> <file>` does the same, and
  the mouse rechecks, rewrites its research document and finishes again. Nothing a person
  or a mouse wrote is typed into a pane, where a newline can send half (ADR-0080).

## Considered options

- **Flip the sniff mouse to build in place.** Keeps the context, but keeps the model and
  effort priced for an investigation.
- **Lettered options after the report** — Build what it proposes, Not now — chosen by the
  branch line. Gone with the skills that wrote them: the person says what happens next
  (ADR-next-one-brief-per-session).
- **Comments go only to the investigating mouse,** which rewrites its research document,
  and the build starts from the id alone. One more round on the model chosen for the
  investigation, when the person often meant the build.
- **Whiska stores the comments on the question.** A new interface and stored field for
  text the person already handed the main session.
- **Type the comments into the prompt, joined into one line and quoted.** The review
  quotes the mouse's text, so its safety rested on escaping hostile text perfectly every
  time.
- **Link the worktree's own file,** as the spec does. It dies with the worktree, and the
  build may start after the person drops it.

## Consequences

- The mice table carries `shaped_as`. A mouse recorded before it reads as shaped as
  nothing and is never flagged; a guess would be a claim.
- The investigation's worktree is left standing after the hand-off: the person may still
  want to talk to it, and `whiska drop` takes it down.
- What the person gives up: a small fix made by the investigating session, which already
  holds the context. They ask for the build, and a fresh mouse reads the proposal.
- A doorstep entry carries an optional `research` field; one without it still decodes.
  The kept copy holds only the latest round; an earlier one is gone once overwritten, as
  an earlier spec is (ADR-0063).
- The owl also writes the research document's exclude line when it opens a house, as it
  does the marker's (ADR-0002), so a worktree shaped before this hides its research
  document too.

Changed on 2026-10-13: the block is **What to change**, with Why and Cost in place of
Touches; the build is `whiska spawn --from`, asked for by the person, with no options
offered; the Needs attention block is gone; the research link shows under any question
from the branch (ADR-next-one-brief-per-session).

Changed on 2026-10-12: the research document is kept once per branch beside the kept spec,
not per question, so an earlier question's link opens the latest round (ADR-0063).
