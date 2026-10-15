# A mouse's report is a document; `whiska show` prints its summary

A mouse's final message that has a `## Summary` heading of its own is a **document**. A
sniff mouse's is its research document; any other mouse's is its report. Whiska keeps it
whole, and `whiska show` prints its summary under the link to it.

## The rule

- **A sniff mouse writes no file.** Its final message is the research document, in this
  order: a `# ` title naming what was investigated, `## Summary` (3-5 lines), `## What to
  change` only when something should change (Found, Build, Why, Cost, Open, ADR-0074),
  `## Question`, `## Found`. Its deny list takes away the file tools, and its brief
  says it changes nothing (ADR-0069). After the person's comments, it sends the whole document again.
- **A build or review mouse's report** starts the same way: a `# ` title saying what is
  true now, then `## Summary`, then each change, then the rest the build brief lists
  (ADR-0049). It is terse prose, no lists and no tables, grammar sacrificed. The Summary
  names each commit by short sha and says what it changed, why it was needed, what
  happens without it, and any risk. Each change gives the review comment in plain words
  when there was one, the problem with an example, the decision and why, what was done,
  and the change: a diff of about 20 lines inline, a bigger one through the Diff or Round
  diff link. One shared section of the build and review briefs, `report_rules.md`, says
  so. A sniff mouse's research document, the spec and the plan keep their lists.
- **Whiska keeps it once per branch, beside the spec.** The `Stop` hook already carries
  the whole message on the doorstep entry (ADR-0036). The owl, collecting it, keeps a
  document's text, marker line removed, as `<the spec's name>.research.md` for a sniff
  mouse and `<the spec's name>.report.md` for any other, overwritten each round, as
  ADR-0063 keeps a spec. A message with no `## Summary` keeps nothing.
- **`whiska show <id>` prints the summary.** The block's head (below), then the `## Summary`
  section and, when there is one, the first line under `## What to change`. A turn that
  ends on a decision keeps the question on the line above its marker. The rest is behind
  the link. `whiska questions --full` prints the same, from the same code. A message with
  no `## Summary`, or an empty one (a question mid-grill, a mouse started before this), is
  printed whole, and so is a turn that stopped with no marker, since it may have been cut
  off.
- **`whiska show` prints the block the person reads; the main brief prints it as is.**
  Its head: a bold title (the `# ` title of the spec, else the report, else the research
  document) when there is one; `Branch: <branch> · <status>`; one line of Markdown links,
  `[diff]`, `[round diff]`, `[research]`, `[spec]`, `[plan]`, `[report]`,
  `[merge request]`, each only when it has something to open; and
  `Delivered blind: herdr could not tell whether this session was idle.` when it was (ADR-0008). The status
  says where it stands: `✓ Ready to merge · N commits`, `✓ Merge request open`,
  `✓ Research done`, `Finished · nothing committed`, `Finished · branch unknown — <why>`,
  `? Needs your decision`, `? Whiska asks`, `! Stopped without saying why`, then what
  applies of commits not pushed, files not committed, held, queued, why it waits, and its
  age once it is a day. A finished question's **branch line** is that status, read from
  git. `round diff` is what the branch changed since its merge request's last review
  round began, read from the `origin` ref recorded then, else the request's head then: a
  `.diff` file beside the diff's, on any question, so the change a "Ready to push" asks
  about opens on its own. `spec` and `plan` link only on a question that is not finished:
  they are what an "ok to build?" asks about, and the report replaces them. Each link is a
  short label, so no path wraps across the terminal's rows, where a click finds no file.
  No question id is in it: the main session has it from the hook (ADR-0009), and the
  person names work by its title or branch. `whiska questions --full` prints the same
  blocks, each under a `#<id>` line, since it lists several.
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
With the message as the document, sniff takes no edit exception, which let its limit move
to Claude Code's own launch flags (ADR-0090), since those
take none.

## Considered options

- **`whiska show` prints labelled facts, and the main brief writes the heading and links
  from them.** The decision until 2026-10-15, so a change to what the person sees would
  be one edit to the brief. Rejected: the model wrote its own heading against the brief,
  and printed the diff's raw path, long enough to wrap, where Cmd+click opened nothing.

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

Changed on 2026-10-15: `whiska show` renders the block, and the brief prints it as is.

Changed on 2026-10-15: the report shows each change in terse prose, with its commit and
its diff, and `whiska show` links a `Round diff`. A mouse fixed a review comment, made a
commit and reported "I fixed it"; the person, who first sees only the Summary, missed
the change. The whole-branch Diff buried a round's fix among the branch's other work.
