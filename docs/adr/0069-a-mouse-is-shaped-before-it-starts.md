# A mouse is shaped before it starts: mode, model and effort

The spawn gives a mouse its shape, its mode, its model and its effort, before Claude
starts. `spawn-worktree` runs `whiska shape build|sniff [--model <name>] [--effort
<level>]` inside the new worktree, after `herdr worktree create` and before `herdr agent
start`. The command mints the marker and the mouse record there and then, records the
shape and `shaped_at`, and prints the flags to start Claude with. The three axes are
chosen apart: the mode says what the mouse may do, the model and the effort say what the
work needs. There is no default mode. A mouse keeps the mode it was shaped with.

## Why before Claude starts

A mouse record is otherwise minted on the first hook call, and the first hook call is a
`PreToolUse`, the very call sniff has to deny. A mode set by `mouse_id` once Claude is
running hands a sniff mouse its first edits as a build mouse. With the shape in the house
before any process exists that could make a tool call, the order is right by
construction. Lazy minting stays as the fallback for a mouse nobody shaped.

## Two modes, no default

**build** produces a real change: edits confined to its own worktree, push needs
approval. **sniff** is investigation only: it writes a report, never a PR, and
`PreToolUse` denies every edit, not only the ones outside the worktree. Both are the same
kind of mouse. The names are deliberately not firstmate's Ship and Scout; no firstmate
vocabulary leaks into this project's language.

A mouse with no `shaped_at` is held to sniff's rules: every edit tool and every shell
command `Whiska.Shell` cannot read as harmless is denied, with a reason that says it was
never given a shape and to ask the person. It cannot shape itself: `whiska` is not on
the read-only list, and `env` and `command` are judged by the command they run, so `env
whiska mode build` is caught too. The person runs `whiska mode build|sniff` in its
worktree, which stamps `shaped_at`. `whiska mode` gives a mode only to a mouse nobody
shaped and refuses a shaped one (ADR-0074): its model and effort were chosen for the
mode's work, so a sniff mouse denied an edit is told to finish with a proposal, not to
ask for `whiska mode build`. `whiska mice` shows an unshaped mouse as `never shaped,
reads only`.

This hold exists because `spawn-worktree` is text and nothing tests that a session
follows it. When build was the default, a skipped `whiska shape` left a mouse asked for
as sniff with write access, and nothing said so.

## Model and effort are chosen by ordered rules

The mode does not say how hard the work is. Tracing one symptom through several parts is
sniff and needs the heaviest model at the highest effort; a described one-line fix is
build and needs neither. `priv/models.json` holds ordered rules for each axis:

```json
"model": {
  "choose": [
    { "when": "a long, open-ended run — …", "use": "fable" },
    { "when": "the task is clear and its shape is already known — …", "use": "sonnet" },
    { "when": "anything else", "use": "opus" }
  ],
  "fallback": ["opus", "sonnet"]
}
```

The first rule that fits wins, so the last rule, `"when": "anything else"`, is the
catch-all and the default; the build refuses a file whose list does not end on it. A
`when` is a judgment about the work, so the session that read the request judges it:
`spawn-worktree` runs `whiska shape --rules`, which prints the file as the build read it,
and passes what it chose as `--model` and `--effort`. A flag left out gets the
catch-all's value; a flag named on the command line wins with no rule applied. The skill
carries neither the rules nor a model name, and a test fails if any file under `lib/` or
any shipped skill names a model the file uses.

Every `use`, fallback and flag value is one plain word: lowercase letters, digits and
dashes. The catch-all alone may be null, for the person's own default. Nothing checks
that a word names a model Claude Code has; a misspelt name passes Whiska and fails in
Claude Code, which is the cost of not keeping a list of models. The plain word is also
what makes the output safe: `whiska shape` prints one line, `--model opus --effort xhigh
--fallback-model sonnet`, or nothing, every word checked, so the spawn can split it with
`eval "set -- $flags"` and it can do nothing but pass flags.

`model.fallback` becomes `--fallback-model`, which Claude Code walks inside the session
when the model is overloaded or not available, retrying the primary each turn. The chain
skips the chosen model. Whiska cannot walk a list itself: `herdr agent start` succeeds as
soon as Claude's prompt is ready, before any request is made, so a quota error arrives
after the spawn has already succeeded.

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
  stale the day one is added or retired.
- **A `may_write` field beside the modes.** The file does not decide what sniff may do,
  so a field saying it did would be a lie.
- **Whiska matching a `when` to the request by keyword.** A worse version of what the
  spawning session already does.

## Consequences

The mice table carries `mode`, `model`, `effort`, `shaped_at`, `shaped_as` and `ran_on`.
`whiska shape` fails non-zero rather than guess, on a bad mode, a value that is not one
plain word, a directory that is no worktree or a house it cannot reach, and checks its
arguments before minting; the skill stops on that and does not start Claude. It writes
what it recorded on stderr, "feat/x is a sniff mouse on opus, xhigh effort", and the
skill's report quotes that line: Whiska's record, not the skill's intent.

Sniff and the hold on an unshaped mouse are not a security boundary. A house that will
not open degrades both to build, loudly, and a missing `whiska` binary allows every call.
Some commands on the read-only list write through a flag (`sort -o`, `rg --pre`, `yq
-i`), and only the four edit tools are denied by name, so an MCP tool that writes is
not. The hold is for a mouse that follows its instructions, not one that fights.

A reviewer in the finish pipeline (ADR-0049) is a third kind of work but not a third
shape: a subagent inside a mouse's session, with no worktree, no marker and no record,
whose model is set in its own agent definition. A mouse started by an older
`spawn-worktree`, or by hand, reads but does not write until the person answers;
re-running `whiska init`, or `whiska init --global`, updates the skill.

Folded in on 2026-10-08: 0018, 0019, 0073 (their text is in git history).
