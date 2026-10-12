# A proposed build

A turn that investigated, changed nothing, and found something that should change ends its
report with a proposal. When the branch has nothing on it, the person's main session
offers it as a fresh build, shaped for that work rather than for the investigation;
otherwise it is there for the person to read. Last before the Agents list, with exactly these
labels:

    **Proposed build**
    - Found: what the investigation established, in a sentence.
    - Build: the change, as a brief a fresh session can start from cold.
    - Touches: the files, modules or parts of the app it changes.
    - Open: the costly choices the investigation leaves open, for the build to grill; none → "none".

- End on the finished marker. Never ask whether to build it, and never end on a decision
  for it: the finished options are where it is offered, and a fresh session builds it.
- One proposal: the build to start first. The lines above it need not repeat it.
- Found nothing that should change → no proposal; the report is the answer.

## The research document

Before the report, write what the investigation established, in full, with the evidence,
then the same block under Proposed build, to `.whiska-research.md` at the worktree root
with the file tool: the `whiska-research` skill's template, its investigation sections. It
is the document the person reviews line by line, and the build reads it with
their comments. Start it with a `# ` heading naming what was investigated: its link shows
that. The report stays short, since the detail is in the research document, and carries
the block as well, since the finished options read it there.

- It is the one file a sniff mouse may write, and git ignores it, so the branch still
  has nothing on it. A mouse nobody shaped may not write it: denied, go on without it.
- Put no link to it in the report: `whiska show` adds one under the branch line.
- No proposal → write one only when the findings outgrow the report.
- Every later finished question links it too, so keep it true: a later turn that changes
  what was found, or what it proposes, rewrites it whole.
