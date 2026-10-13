# A mouse's report is a document; `whiska show` prints its summary

A mouse's final message that has a `## Summary` heading of its own is a **document**. A
sniff mouse's is its research document; any other mouse's is its report. Whiska keeps it
whole, and `whiska show` prints its summary under the link to it.

## The rule

- **A sniff mouse writes no file.** Its final message is the research document, in this
  order: a `# ` title naming what was investigated, `## Summary` (3-5 lines), `## What to
  change` only when something should change (Found, Build, Why, Cost, Open, ADR-0074),
  `## Question`, `## Found`. `PreToolUse` denies it every edit, with no exception
  (ADR-0069). After the person's comments, it sends the whole document again.
- **A build mouse's report** starts the same way: a `# ` title saying what is true now,
  then `## Summary`, then the rest the build brief lists (ADR-0049).
- **Whiska keeps it once per branch, beside the spec.** The `Stop` hook already carries
  the whole message on the doorstep entry (ADR-0036). The owl, collecting it, keeps a
  document's text, marker line removed, as `<the spec's name>.research.md` for a sniff
  mouse and `<the spec's name>.report.md` for any other, overwritten each round, as
  ADR-0063 keeps a spec. A message with no `## Summary` keeps nothing.
- **`whiska show <id>` prints the summary.** The heading, one row of links
  (the diff, research, spec, build plan and now the report), then the `## Summary`
  section and, when there is one, the first line under `## What to change`. A turn that
  ends on a decision keeps the question on the line above its marker. The rest is behind
  the link. `whiska questions --full` prints the same, from the same code. A message with
  no `## Summary`, or an empty one (a question mid-grill, a mouse started before this), is
  printed whole, and so is a turn that stopped with no marker, since it may have been cut
  off.
- **A finished report's heading and links are short.** `#<id> <branch> · finished <time>
  · <branch state>`: the time is when it finished (with its date, when not today), the
  state only when it is not plain waiting on the person, and the branch state folded in
  (`1 commit, clean`). Under it one row of labels, `Diff · Research · Full report`, each
  only when it has something to open. `Spec` and `Build plan` link only on a question
  that is not finished: they are what an "ok to build?" asks about, and the report
  replaces them. Other questions keep their heading's state and day, and take the same
  row.
- **A heading inside a code block is not one.** A message quoting the template is not a
  document.
- **The heading never decides what the turn is.** Its kind is its marker's alone
  (ADR-0009); the heading decides only what Whiska keeps and how much it prints.

## Why

A finished investigation printed whole filled the main session's screen with findings the
person reads better in their review tool, where they can comment line by line, and the
research document said the same things again. Two copies of one report drifted. One
document, kept by Whiska, read in full from its link and in brief from `whiska show`, is
one source.

The sniff mouse's single write exception existed only so it could write that document.
With the message as the document, sniff denies every edit, which also lets the guard move
to Claude Code's own launch flags one day, since those take no exception.

## Considered options

- **The mouse writes `.whiska-research.md`, and the report repeats it in short** (as
  before). Two copies, and a write exception in a mode whose point is writing nothing.
- **The `Stop` hook writes the file itself.** It would have to read the mouse's mode from
  the house and classify the message, which ADR-0009 leaves to the owl; the hook stays a
  plain writer, and the entry's format does not change.
- **Keep the document by the marker** (only a `done` turn). The heading is what the brief
  asks for and what `whiska show` reads, so one test decides both, and a finished report
  that ends on a decision is kept too.
- **Print the first lines of any message.** A cut the mouse does not write for: the
  summary is the mouse's own, written to be read alone.

## Consequences

- ADR-0069's rejected option, "Whiska writes the document from the mouse's final
  message", is now the rule. Its objection was the comments: the mouse could not rewrite
  a document it did not write. It does now, by sending it again.
- A build mouse fixing a bug still writes `.whiska-research.md` for the person's ok
  before any code (ADR-0063); the `Stop` hook still carries it, and its exclude line
  stays.
- What the person gives up: the full findings in `whiska show`'s output. The link opens
  them, and the main session reads the kept file when asked what a mouse found.
- `whiska spawn --from <id>` points the new mouse at the research document for the Build
  line, which `whiska show` no longer prints.
- A heading is prose. A mouse that leaves out `## Summary` is printed whole and nothing is
  kept, which is the loud failure: the person sees the whole message.
- The mouse chooses what the person reads first. `whiska pr` sends the whole report as
  the merge request's description, and `spawn --from` hands its Found to the next mouse
  as fact; both are behind the links `whiska show` prints, not on screen.
