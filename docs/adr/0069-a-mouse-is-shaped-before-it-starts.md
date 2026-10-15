# A mouse is shaped before it starts: mode, model and effort

The spawn gives a mouse its shape, its mode, its model and its effort, before Claude
starts. `whiska spawn` shapes it after herdr creates the worktree and before Claude starts
there (ADR-0088); `whiska shape build|sniff [--model <name>]
[--effort <level>]`, run inside a worktree, does the same for a mouse started by hand.
Either mints the marker and the mouse record there and then, records the shape and
`shaped_at`, writes the mouse's brief — its mode's — to
`.whiska-brief.md` and its mode's deny list to `.whiska-settings.json` at the worktree
root, both of which git ignores, and gives the flags to start Claude with,
`--dangerously-skip-permissions --settings .whiska-settings.json
--append-system-prompt-file .whiska-brief.md` among them
(ADR-0090). The three axes are chosen apart: the mode says what the mouse may do, the model and the effort say what the
work needs. There is no default mode. A mouse keeps the mode it was shaped with.

## Why before Claude starts

A mode reaches Claude as its launch flags, the deny list among them, and a running
session cannot take new ones. With the shape written before any process exists that could
make a tool call, the order is right by construction. Lazy minting on the first hook call
stays as the fallback for a mouse nobody shaped.

## Two modes, no default

**build** produces a real change, in its own worktree as its brief says; push approval
is designed, not built (ADR-0011). **sniff** is investigation only: it writes a report, never a PR, and
its deny list takes away `Edit`, `Write` and `NotebookEdit`. Its **research
document** is its final message, which Whiska keeps (ADR-0089),
so there is no file for it to write.
Both are the same kind of mouse. The names are deliberately not firstmate's Ship and Scout; no firstmate
vocabulary leaks into this project's language.

A mouse with no `shaped_at` starts with no deny list and is not limited: one started by
hand, or by an older Whiska. `whiska mode` gives it no mode, since a mode is a launch
flag; the person runs `whiska shape <mode>` in its worktree and restarts Claude with the
flags it prints. `whiska mode` refuses a shaped mouse (ADR-0074): its model and effort
were chosen for the mode's work, so a sniff mouse that finds something to change ends on
a What to change block. `whiska mice` shows an unshaped mouse as `never shaped`.

## Model and effort are chosen by ordered rules

The mode does not say how hard the work is. Tracing one symptom through several parts is
sniff and needs the heaviest model at the highest effort; a described one-line fix is
build and needs neither. `priv/models.json` holds ordered rules for each axis:

```json
"model": {
  "choose": [
    { "when": "a long, open-ended run — …", "use": "fable" },
    { "when": "a small, fully spelled-out change — …", "use": "haiku" },
    { "when": "the task is clear and its shape is already known — …", "use": "sonnet" },
    { "when": "anything else", "use": "opus" }
  ],
  "fallback": ["opus", "sonnet"]
}
```

The first rule that fits wins, so the last rule, `"when": "anything else"`, is the
catch-all and the default; the build refuses a file whose list does not end on it. A
`when` is a judgment about the work, so the session that read the request judges it: the
main session runs `whiska shape --rules`, which prints the file as the build read it, and
passes what it chose to `whiska spawn` as `--model` and `--effort`. A flag left out gets
the catch-all's value; a flag named on the command line wins with no rule applied. The
main session's brief carries neither the rules nor a model name.

Every `use`, fallback and flag value is one plain word: lowercase letters, digits and
dashes. The catch-all alone may be null, for the person's own default. Nothing checks
that a word names a model Claude Code has; a misspelt name passes Whiska and fails in
Claude Code, which is the cost of not keeping a list of models. The plain word is also
what makes the output safe: `whiska shape` prints one line, `--model opus --effort xhigh
--fallback-model sonnet --dangerously-skip-permissions --settings .whiska-settings.json
--append-system-prompt-file .whiska-brief.md`, every word checked, so a mouse started by
hand can split it with `eval "set -- $flags"` and it can do nothing but pass flags.
`whiska spawn` hands herdr the same flags as separate words.

`model.fallback` becomes `--fallback-model`, which Claude Code walks inside the session
when the model is overloaded or not available, retrying the primary each turn. The chain
skips the chosen model. Whiska cannot walk a list itself: `herdr agent start` succeeds as
soon as Claude's prompt is ready, before any request is made, so a quota error arrives
after the spawn has already succeeded.

## A mouse gets an auto-compact window

`model.autocompact` in `priv/models.json` maps a model word to a window in tokens, with a
`default` that every model not named gets: `{"default": 300000, "haiku": 100000}`.
`whiska shape`, either mode, appends `--autocompact <tokens>` for the chosen model, so a
sniff mouse is held to the same window as a build mouse. The build
refuses a file with no `default` or a value outside 100000 to 1000000, the range Claude
Code accepts. Claude Code compacts at about 967K by default, which a sniff mouse
reached before it got the window. The person chose 300K for the
1M models and 100K for haiku, a window that is the lowest Claude Code allows. These are
the person's judgment: Anthropic publishes no per-model quality curve, so no source backs
the numbers.

The flag is fixed at launch, so a mouse that falls back keeps the window of the model it
started on. The fallback chain is opus then sonnet and both take the default, so the
fallback never changes the window today. The map names a model only to give it a window
of its own; which models exist is still Claude Code's to say, and a model the map does
not name still gets the default.

The record keeps the model and effort the spawn asked for, and `ran_on`: the full model
id the mouse's latest turn ran on. The `Stop` hook reads it from `message.model` on the
session's own latest assistant entry, skipping a subagent's entries and the `<synthetic>`
stamp on a message no model sent, and carries it on the doorstep entry; the owl records
it on collection. So the spawn pins no version and the record is still exact, fallback
included.

## Considered options

- **A mode file beside `.whiska-mouse`, read at minting.** The mode would live in two
  places, and the marker stays a bare id with no parsing (ADR-0002).
- **A ranked model list per mode in `dispatch.yml`, walked when a spawn fails on quota.**
  A quota error cannot drive the walk, since the spawn has already succeeded when it
  arrives, and Whiska targets one harness.
- **A model tied to the mode.** The mode says what the mouse may do, not how hard the
  work is.
- **A list of model names in Whiska.** Claude Code owns which models exist; the list is
  stale the day one is added or retired. The `autocompact` map is not this list: it
  needs no entry for a model, and the `default` covers every one it does not name.
- **Setting the window in the person's `settings.json` with `modelSettings`.** It follows
  a fallback to another model, but needs Claude Code 2.1.288 or later, reaches the main
  session and subagents too, and keeps the numbers outside Whiska.
- **A `may_write` field beside the modes.** The file does not decide what sniff may do,
  so a field saying it did would be a lie.
- **A research document the sniff mouse writes itself,** as the one file it may write.
  Chosen first, then dropped: two copies of one report, and an exception in a mode whose
  point is writing nothing (ADR-0089).
- **Whiska matching a `when` to the request by keyword.** A worse version of what the
  spawning session already does.

## Consequences

The mice table carries `mode`, `model`, `effort`, `shaped_at`, `shaped_as` and `ran_on`.
`whiska shape` fails non-zero rather than guess, on a bad mode, a value that is not one
plain word, a directory that is no worktree or a house it cannot reach, and checks its
arguments before minting; `whiska spawn` stops on that and does not start Claude. It says
what it recorded, "feat/x is a sniff mouse on opus, xhigh effort", and `whiska spawn`'s
report carries that line: Whiska's record, not the main session's intent.

Sniff is not a security boundary. Only the edit tools are denied by name, so a shell
command or an MCP tool that writes is not. It is for a mouse that follows its
instructions, not one that fights (ADR-0090).

A reviewer in the finish pipeline (ADR-0049) is a third kind of work but not a third
shape: a subagent inside a mouse's session, with no worktree, no marker and no record,
whose model is set in its own agent definition.

Folded in on 2026-10-08: 0018, 0019, 0073 (their text is in git history).

Changed on 2026-10-13: `whiska spawn` shapes the mouse, and the shape writes its brief and
adds it to the flags (ADR-0088).

Changed on 2026-10-13: a sniff mouse writes no file; its final message is the research
document, and every edit is denied (ADR-0089).

Changed on 2026-10-14: a mode is the deny list a mouse starts with, in bypass mode, and a
mouse nobody shaped is not limited (ADR-0090).

Changed on 2026-10-15: a sniff mouse gets the auto-compact window too; only a build mouse
did, and a sniff mouse grew to Claude Code's ~967K default.

Changed on 2026-10-15: the flags are Claude's launch line only, so a mouse herdr restored
as a bare `claude --resume` after a server restart lost them. The owl starts such a mouse
again with `--resume` and the same flags, rebuilt from its record and the brief and deny
list already in its worktree (ADR-0044).
