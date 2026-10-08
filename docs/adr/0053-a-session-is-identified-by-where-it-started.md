# A session is identified by where it started and which pane it runs in

Both hooks used to ask one question to find out whose session they were in: what working
directory did Claude Code pass? `Layout.resolve/1` turned that into a worktree root, a
branch label and a main checkout, and everything downstream — the marker file, the mouse
record, the containment rule, the doorstep entry — followed from it.

That directory is not an identity. It follows every `cd` the session runs, because Claude
Code's Bash tool keeps its working directory between calls. Seen in a real repo on
2026-09-29: a person's main session ran one command that stepped into `worktrees/<branch>`,
and on its next stop the `Stop` hook read that directory, concluded it was that branch's
mouse, and left the person's own reply on the doorstep as a message from a branch nobody
was working on. It was delivered back to them as an unmarked question, twice.

The same reading is wrong in the other direction too. A mouse that steps out of its
worktree — into the main checkout to read something, into `/tmp` — resolves to no worktree
at all, and its whole final message is dropped in silence.

## Decision

A session is identified by where it started and which pane it runs in. Neither moves for
the session's whole life. The working directory is a position, and is never read as an
identity again.

**The pane is the stronger signal.** The hook runs with herdr's `HERDR_PANE_ID` in its
environment, and the house already records the main session's pane, put there by
`whiska start` (ADR-0020). A hook firing in that pane is the person's own session
whatever any directory says: it is no mouse, it writes nothing to the doorstep, it mints
no marker, and no rule is applied to it.

**The start directory is the weaker one.** Claude Code stamps every transcript entry with
the session's working directory; the first entry predates any `cd`. So the worktree a
session speaks for is derived from that first entry, and only from the payload's working
directory when there is no transcript, or none that names a directory.

`Whiska.Session` is where both live. `Layout` is untouched — it still turns *a* directory
into a worktree (ADR-0030); what changed is which directory it is handed.

## Consequences

The main session can stand wherever it likes. Its stops leave nothing behind, and
`Rule.MainCheckout` no longer blocks it from editing its own checkout after a `cd` — a
second symptom of the same bug, which would have read as Whiska denying the person's own
work for no stated reason.

A mouse can stand wherever it likes too. It is still the mouse of the worktree it started
in, still held to that worktree by the containment rule, and its message still reaches
that worktree's house.

The `Stop` hook now opens the house, where before it only wrote a file — opening migrates
it, so this is a write and not only a read. ADR-0036 still holds, and carries a note
saying so: no socket is opened and nothing depends on the owl being up. But `Stop` must
survive a database that will not open, because it has a mouse's whole final message to
leave, so the pane read runs through `Whiska.Isolated` — an unlinked, monitored process
with a deadline — exactly as `PreToolUse` already ran its own house work. An unreadable
house then means no pane claim rather than a lost message: the session is treated as the
mouse it looks like, which is where identity already was. Nothing is opened twice: in
`PreToolUse` the pane and the mode come out of the one house opening the hook already
did, and with no `HERDR_PANE_ID` in the environment `Stop` does not open it at all.

Measured on 2026-09-30, 30 invocations each, against the 141 ms escript boot floor
ADR-0033 is really about. `PreToolUse` is unchanged within noise at 228 ms: reading the
start directory takes 0.12 ms on a real transcript, and the pane comes out of the house
opening the hook already did. `Stop` gained about 70 ms per finished turn — a cold VM has
to start `:ecto_sql`, load the bundled SQLite library and run the migrator to read one
column. Once per turn, which is the trade worth making; the alternative is a mouse's
message filed under the wrong branch.

The transcript read is bounded three ways: 200 lines, a megabyte in total, and any single
line over 64 KB skipped without parsing it. A line budget rather than only a byte one,
because one opening paste can be larger than any sensible byte window and cutting the read
there would answer "started nowhere" for a session that plainly did. Without the ceilings
a transcript of fat entries cost 100 ms on every matched tool call.

Two limits are worth writing down rather than discovering. **The start directory is read
from a file the containment rule permits writing.** A mouse may edit its own transcript —
`~/.claude/projects/` is outside both its worktree and the main checkout, and ADR-0013's
rule allows it — and so make itself look like it started somewhere else. This is not a new
hole so much as a new shape of the old one: a mouse can already disable the hook outright
by editing `.claude/settings.json` inside its own worktree, and ADR-0024 records the honest
limit that everything here runs as one OS user with no sandboxing. **And a herdr pane id is
positional.** If the main session's pane closes and herdr gives `w1:p2` to a worktree pane,
that mouse reads as the main session — no rules applied, nothing written — until
`whiska start` is run again. `whiska doctor` already reports the recorded pane; noticing
that it is now a mouse's is not built.

Two signals rather than one is deliberate. Either alone leaves a hole: with no herdr
around there is no pane to compare, and a session Claude Code wrote no transcript for has
only its working directory. Neither fallback is worse than the behaviour they replace.

## Alternatives

**Decode the start directory from `transcript_path` instead.** Claude Code names the
transcript's folder after the start directory with every non-alphanumeric character
replaced by a dash, so `~/.claude/projects/-Users-me-repo-worktrees-feat/<session>.jsonl`
carries the answer. It is lossy — a dash, a dot and a slash all encode the same — so
recovering the real path means walking the filesystem and backtracking. The first entry
inside the file is the same fact, exact, and read with one `File.open`.

**Require the working directory and the start directory to agree.** Cheaper, and it stops
the reported bug, but it answers "not sure" for the mouse that stepped out, which is the
case where silence costs a whole message.

**Record the worktree root in the marker file.** The marker sits in the worktree, so
finding it still means starting from a directory. It also breaks ADR-0002's "no parsing
involved" for no gain here.
