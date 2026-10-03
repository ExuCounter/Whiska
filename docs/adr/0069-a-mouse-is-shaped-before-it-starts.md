# A mouse is shaped before it starts, and its shape carries its model

Sniff mode was enforced (ADR-0018) and unreachable: nothing ever set it, so every mouse
ran as build. Setting it after the fact does not work. A mouse record is minted on the
first hook call (ADR-0030), and the first hook call is a `PreToolUse` — the call sniff
has to deny — so a mode set by `mouse_id` once Claude is running hands a sniff mouse its
first edits as a build mouse.

So the spawn gives a mouse its **shape** — its mode and its model — before Claude
starts. `spawn-worktree` runs `whiska shape build|sniff [--model <alias>]` inside the
new worktree, after `herdr worktree create` and before `herdr agent start`. The command
mints the marker and the mouse record there and then (as `whiska mode` already could),
records the mode, the model and `shaped_at`, and prints the model to start Claude on.
The order is right by construction: the shape is in the house before any process
exists that could make a tool call.

## Not a second marker file

The obvious alternative was a mode file beside `.whiska-mouse`, read at minting. It was
rejected:

- The mode would live in two places. `whiska mode build` changes the house; the file
  would go on saying sniff, and whichever one the code read first would win.
- ADR-0002 keeps the marker a bare id with no parsing, and `Storage.set_mode/2` already
  keeps the mode in the house so a renamed branch or a moved folder does not disturb it.
- Nothing needed it. Minting early is what ADR-0002 described in the first place — the
  id written at worktree creation, by a script. ADR-0030 made it lazy only so its first
  slice did not have to change `spawn-worktree`. Lazy minting stays, as the fallback for
  a mouse nobody shaped.

## The model belongs to the shape

Investigation is a lighter job than building. A sniff mouse starts on `sonnet`; a build
mouse passes no `--model` and keeps the person's own Claude Code default. A spawn may
name another — `fable`, `opus` or `sonnet` — for either. The aliases resolve to the
latest of each family, so Whiska names no version. `herdr agent start ... -- --model
<alias>` hands everything after `--` to `claude` unchanged; checked on 2026-10-03 by
starting one and reading the process's arguments.

This replaces ADR-0019 (superseded). It put the per-mode default in a person-written
`.whiska/dispatch.yml`, as a ranked list walked down when a spawn failed on quota. With
aliases there is nothing per-repo to keep current, Whiska targets one harness, and a
quota error cannot drive the walk: `herdr agent start` succeeds as soon as Claude's
prompt is ready, before any request is made, so the error arrives after the spawn has
already succeeded. What that costs: the default is changed in Whiska, not in
`dispatch.yml` (which keeps its other settings), and a mouse that runs out of quota
stops like any other session instead of moving to the next model.

## A spawn that forgets is stopped, and asks

`spawn-worktree` is text, and nothing tests that a session follows it. If it skips
`whiska shape`, nothing set the mode. Under ADR-0018 as it stood, that mouse was build,
so a branch asked for as sniff came out with write access and nobody was told. So a
mouse with no `shaped_at` is held to sniff's rules instead — every edit tool and every
shell command `Whiska.Shell` cannot read as harmless is denied — and the reason says it
was never given a shape and to ask the person. It cannot shape itself: `whiska mode` is
not on the read-only list. The person runs `whiska mode build` or `whiska mode sniff` in
its worktree, which stamps `shaped_at`. ADR-0018 is rewritten to match: there is no
default mode.

Around that:

- `whiska shape` fails non-zero rather than guess — bad mode, bad model, not a worktree,
  house unreachable — and checks its arguments before minting anything. The skill says
  to stop on that and not start Claude.
- It writes what it recorded on stderr ("feat/x is a sniff mouse on sonnet."), and the
  skill's report quotes that line word for word: Whiska's record, not the skill's intent.
- `whiska mice` shows a mouse nobody shaped as `never shaped, reads only`.

What it costs: a mouse started by an older copy of `spawn-worktree`, or by hand, can
read but not write until the person answers. Re-running `whiska init` updates the skill;
`whiska init --global` updates the machine-wide copy. Mice already recorded when
migration 7 ran were stamped as shaped, since they were running as build and their
spawn could not have shaped them.

## Not reviewers

A reviewer in the finish pipeline (ADR-0049) is a third kind of work, but not a third
shape. It is a subagent inside a mouse's session — no worktree, no marker, no record,
nothing `PreToolUse` enforces for it — and ADR-0054 leaves the roster to whatever the
session has. Its model is set in its own agent definition, which the person owns.

## Consequences

The mice table gains `model` and `shaped_at` (migration 7). Sniff, and the hold on
a mouse nobody shaped, are still not a security boundary: a house that will not open degrades both to build, loudly
(`Whiska.Hook.PreToolUse`), and a missing `whiska` binary allows every call.
