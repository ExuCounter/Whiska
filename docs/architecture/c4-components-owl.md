# Component Diagram — the owl

Level 3 for the owl, which is real code as of the owl slice. Everything here is in
`lib/whiska/owl/`, `lib/whiska/doorstep*`, `lib/whiska/herdr*` and
`lib/whiska/question/marker.ex`, each with a test beside it.

```mermaid
C4Component
  title Component Diagram - the owl

  System_Ext(herdrd, "herdr", "Panes and agent status")
  Container_Ext(cliboot, "whiska owl", "escript command", "Boots the owl in the foreground")

  Container_Boundary(owl, "Owl") {
    Component(sup, "Whiska.Owl", "Supervisor", "One House per open project, each supervised alone")
    Component(house, "Whiska.Owl.House", "GenServer", "Pane discovery, subscription, collection")
    Component(herdrb, "Whiska.Herdr", "behaviour", "The one mocked boundary (ADR-0031)")
    Component(sock, "Whiska.Herdr.Socket", "gen_tcp on a Unix socket", "Newline-delimited JSON; list_panes and subscribe")
    Component(doorstep, "Whiska.Doorstep", "file store", "Reads entries, marks them collected by rename")
    Component(entry, "Whiska.Doorstep.Entry", "struct", "mouse_id, branch, worktree_root, stamped_at, text")
    Component(markerq, "Whiska.Question.Marker", "classifier", "done / needs-decision / unmarked, by marker alone")
    Component(storage, "Whiska.Storage", "Ecto", "Questions, mode, dead mice")
  }

  ContainerDb(db, "House database", "SQLite", "mice and questions")

  Rel(cliboot, sup, "Starts with the repos to open")
  Rel(sup, house, "Opens and shuts")
  Rel(house, herdrb, "Lists panes, subscribes")
  Rel(herdrb, sock, "Dispatched to the configured implementation")
  Rel(sock, herdrd, "One request per connection; events stream")
  Rel(house, doorstep, "Collects")
  Rel(doorstep, entry, "Decodes each JSON file")
  Rel(house, markerq, "Classifies each entry's text")
  Rel(house, storage, "Writes questions, marks mice dead")
  Rel(storage, db, "Ecto/exqlite")

  UpdateLayoutConfig($c4ShapeInRow="4", $c4BoundaryInRow="1")
```

## The load-bearing choices

**Pane discovery exists because the subscription is per pane.** Checked against herdr
0.8.2: `pane.agent_status_changed` needs a named `pane_id` and rejects a wildcard, while
`pane.closed`, `pane.exited` and `pane.agent_detected` are global. So a house matches each
pane's `cwd` up to a mouse record's worktree path, records the pane id on the mouse — the
first and only thing that ever fills ADR-0006's `pane` column — and reopens the
subscription whenever that set changes. A dropped connection is retried with a wait, and
kept being retried while herdr is down.

**Three collection triggers, only one a timer.** A mouse pane going idle, the house
opening, and a slow backstop. Collection reads and marks; it never deletes and never
touches the worktree (ADR-0007).

**Classification is the marker and nothing else** (ADR-0009). `Whiska.Question.Marker`
scans for `[worktree-status: …]` and maps it to `done`, `needs-decision` or `unmarked`;
anything unrecognised is `unmarked`, which is delivered. The invisible-character prefix is
treated as optional — it is a courtesy to whoever reads the transcript, not part of the
marker's meaning, so a mouse that drops it is not misread as having said nothing.

**The hook does not classify.** `Whiska.Hook.Stop` writes the raw final message and exits;
the owl reads the marker on collection. That keeps the writer dumb and puts the one piece
of judgment on the side that can be changed without touching every mouse's `settings.json`.

**A `done` report is closed on arrival** — status `closed`, never delivered, never
answered. An entry whose worktree is gone is `orphaned`: recorded, surfaced, never
interrupting, because there is nowhere to reply and nothing left to change.

**Dead mice are marked, not deleted.** `pane.closed` or `pane.exited` on a known mouse
pane stamps `died_at` (the V002 migration's one column) and cascades that mouse's open
questions to `orphaned` (ADR-0026, ADR-0007). A mouse with no pane anywhere at house open
is dead too, found by reconciling against `pane.list`.
