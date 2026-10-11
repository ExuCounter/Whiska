# Usage is recorded at collection, read from the transcript the entry names

**The owl records what each turn cost when it collects that turn's doorstep entry.** The
`Stop` hook puts the session's transcript path on the entry, beside `ran_on` and the spec
(ADR-0036). At collection the owl reads that turn with the ledger (ADR-0049), cut off at
the entry's stamp, and stores one **usage** row per ledger line, keyed by the question.

- **A row covers one turn.** The mouse's row runs from the prompt that started the turn —
  the last one with `origin.kind` `"human"`, which is also how an answer handed over or a
  pickup arrives — to the stop. Agent rows are the agents sent in that turn, as the ledger
  already scopes them. Rows add up, so a mouse's usage is a sum.
- **One turn, one set of rows.** A second entry can name a turn already collected: the
  escript writing again for a turn the owl wrote (ADR-0036), or a session a background task
  woke stopping again with no prompt in between. Each row carries its transcript and the
  turn's start, and the later entry's rows mark the earlier ones `replaced`. They are kept
  (ADR-0007); the rows not replaced add up.
- **Cut at the stamp.** Collection can come late, with the owl down or on the backstop,
  and by then the mouse may be in its next turn. Nothing written after the stamp is read.
- **Best effort**, like the spec copy (ADR-0063). An entry naming no transcript, written
  before this, is collected with no rows and nothing said. One naming a transcript that is
  not there, not a plain `.jsonl` file, or past the size cap is collected with no rows and
  a line in the owl log. The question is never held back for its usage.
- **Tokens only.** No price list: it would be a list of models, which ADR-0069 keeps out,
  and it goes wrong without a sound the day prices change. `whiska metrics` weighs tokens
  into cost units, input + 1.25 × cache writes + 0.1 × cache reads + 5 × output, the ratio
  every Claude model is priced at.
- **Two stamps ride on the question**: `answered_at`, set by `reply` and never by the
  carry-on line `resume` types, and `spec_sent`, set when the spec copy is written new or
  revised. With them the house holds every wait and the spec's timing as well as the cost.
  The ok is the first answer from the last spec question on, since the person may answer a
  second entry for that turn, which carries the spec unchanged.
- **No backfill.** Older questions name no transcript, and matching one by folder and time
  can land a turn on the wrong question.
- **`whiska ledger` is on the read-only list** (ADR-0034), so a sniff mouse can read its
  own usage like any other. No other `whiska` command is: every one that opens the
  house can migrate it, and the rest change something. Nor is the ledger with any variable
  set in front of it, since it needs none. The Erlang VM takes code from `ERL_AFLAGS`,
  `ERL_FLAGS` and `ERL_ZFLAGS` and another emulator from `ESCRIPT_EMULATOR`, so setting any
  of them counts as a write wherever it happens: in front of a wrapper such as `env` or
  `find -exec`, in an earlier part of the line, or through `printf -v`.

## Why at collection, from the transcript

Before this, usage reached the house only as prose: a copy of the ledger in 13 of 322
finished reports, none from a sniff mouse, which `whiska` was denied to. Every question
about cost meant a research mouse reading transcripts by hand.

- **The mouse reports its own usage.** That is its claim, read back out of prose, and a
  sniff mouse could not make it.
- **The `Stop` hook reads the ledger and carries the figures.** Every turn's end would pay
  a full read of the transcript and every agent's beside it, inside the hook Claude Code
  waits on, in the escript as well as the owl. At collection the house pays it, once per
  entry, and the mouse does not wait at all: 72 ms for the largest whiska transcript on
  this machine, 14 MB, on 2026-10-11. Each entry keeps only the fields a line is counted
  from, and an agent's file last written before the turn began is not read.
- **The owl reads transcripts on a timer, as the board does (ADR-0050).** A timer has no
  question to key a row to.

Collection is where a turn becomes a question. Keying usage to the question is what lets
the metrics put cost beside waits and spec timing.

## Consequences

- Transcripts live under `~/.claude/projects`, outside the worktree, so removing a worktree
  loses none. Claude Code's own cleanup does, after 30 days by default, which is why they
  are read at collection rather than later.
- A turn that never reaches a stop, cut off by hand or dead, leaves no row.
- What a reviewer found is not recorded here. That is a record the mouse would write, and
  a decision of its own.
