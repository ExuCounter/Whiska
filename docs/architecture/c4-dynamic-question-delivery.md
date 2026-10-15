# Dynamic — a question from doorstep to answer

All of this is built. The doorstep and collection are ADR-0036, classification ADR-0009,
the hook's reading of the transcript before it writes ADR-0052, the queue and its hold
while the person is typing ADR-0008 and ADR-0047, the hoot and the reminder ADR-0062,
the reply keyed to a question id ADR-0005, and the answer taken by the mouse's own hook
ADR-0080. Shown as a dynamic diagram because the ordering is the design. Nothing here
crosses into another repo (ADR-0044).

> Mermaid numbers a `C4Dynamic` diagram's relationships itself, in declaration
> order — so the order of the `Rel` lines below is the flow.

```mermaid
C4Dynamic
  title Dynamic Diagram - question delivery

  Person(person, "The person", "Answers one at a time")
  Container_Ext(mousepane, "Mouse", "Claude Code in a herdr pane", "Just finished a turn")
  Container_Ext(herdr, "herdr", "Multiplexer", "Reports agent status from a real hook")
  Container_Ext(mainpane, "Main session", "Claude Code", "The pane whiska start ran in")
  ContainerDb_Ext(jsonl, "Session transcript", "JSONL in ~/.claude/projects", "Claude Code writes it as the turn runs")

  Container_Boundary(owl, "Owl") {
    Component(doorstep, "Doorstep", "directory", "Uncollected entries")
    Component(collection, "Collection", "per house", "Reads and marks, never deletes")
    Component(delivery, "Delivery", "per house, a queue", "One question at a time, when idle; a done report never enters it")
  }

  ContainerDb(db, "House database", "SQLite", "questions")

  Rel(mousepane, jsonl, "End of a turn: the stop hook reads the tail. No marker and background work still out, and it writes nothing")
  Rel(mousepane, doorstep, "Otherwise the turn is over: one entry lands, written by the owl over its hook socket, or by the escript when the owl does not answer")
  Rel(herdr, collection, "Reports that mouse done or idle, unless the owl that wrote the entry has already asked")
  Rel(collection, doorstep, "Collect what is there")
  Rel(collection, db, "Record as a question, classified by its worktree-status marker; a done report is recorded closed")
  Rel(collection, herdr, "A done report: one hoot now, then a reminder every two hours while its branch has work to land")
  Rel(delivery, db, "Release what nothing can answer; then, among what the person has not set aside (away, focus, hold), and only if the slot is free: a superseded question's heir, then a letter's reply, otherwise the oldest open question")
  Rel(delivery, herdr, "Is the prompt box empty? reads the main pane's screen")
  Rel(delivery, mainpane, "Type one line only if idle, nothing half-typed and nothing sent")
  Rel(delivery, herdr, "Hoot: one desktop notification, raised in the same breath as the line")
  Rel(herdr, person, "Shows it, wherever they are")
  Rel(delivery, person, "If herdr's popups are off or nobody is attached: the same hoot, on the desktop")
  Rel(person, db, "whiska reply, keyed to the question id, saves the answer first")
  Rel(person, mousepane, "Then rings its doorbell through herdr: one fixed line, never the answer")
  Rel(mousepane, db, "Its UserPromptSubmit hook reads the answer, hands it over as context, stamps it taken")
  Rel(delivery, mousepane, "Not taken: rings again on the backstop, at most three times, then tells the person")

  UpdateRelStyle(mousepane, doorstep, $textColor="blue", $lineColor="blue", $offsetY="-20")
  UpdateLayoutConfig($c4ShapeInRow="4", $c4BoundaryInRow="1")
```

Finishing happens before any of this, inside the turn: the mouse follows its brief's
finishing steps, reading the change back, a fresh reviewer, a commit on its branch, and
only then writes the marker (ADR-0049). Nothing sits in front of the stop hook, and
nothing in Whiska knows whether those steps ran.

After a delivered line, the main session runs `whiska show`, renders the question by its brief's rule and stops;
the person says what happens next, and the main session runs `whiska reply`, `land`, `pr`,
`drop` or `send` for it (ADR-0088).
