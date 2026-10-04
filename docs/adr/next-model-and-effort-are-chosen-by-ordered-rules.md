# Model and effort are chosen by ordered rules, apart from the mode

ADR-0069 tied a mouse's model to its mode: sniff started on a lighter model, build on
the person's own default, and `priv/models.json` listed the model aliases and each
mode's default. Both halves were wrong.

- **The mode does not say how hard the work is.** It says what the mouse may do. Tracing
  one symptom through several parts is sniff, and it needs the heaviest model and the
  most effort; a described one-line fix is build, and needs neither.
- **A list of model names is Whiska asserting which models exist.** Claude Code owns
  that, and the list is stale the day a model is added or retired. Which models are
  available is something to discover, not a mapping to keep.

## Three axes, set apart

A shape is now three things, each chosen on its own:

- **Mode** — what the mouse may do: build or sniff. The hook enforces it (ADR-0018). The
  file only says when each applies. A `may_write` field beside the modes was rejected:
  the file does not decide what sniff may do, so a field saying it did would be a lie.
- **Model** — what kind of thinking the work needs. `claude --model`.
- **Effort** — how much of it. `claude --effort`.

A hard investigation is sniff, on the heaviest model, at the highest effort; nothing
about one axis implies another.

## The rules are sentences, judged by the spawning session

`priv/models.json` holds all three:

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

Each `choose` list is ordered and the first rule that fits wins, so the last rule is the
catch-all — `"when": "anything else"` — and the default. The build refuses a file
whose list does not end on it, or that puts it anywhere earlier, where it would hide
every rule after it.

A `when` is a judgment about the work, so the session that read the request judges it.
`spawn-worktree` runs `whiska shape --rules`, which prints the file as the build read it
(the escript carries no `priv/`), and passes what it chose as `--model` and `--effort`.
The skill carries neither the rules nor a model name; a test fails if any file under
`lib/` or any shipped skill names a model the file uses.

`whiska shape` applies one rule itself: the catch-all, for a flag left out. A flag named
on the command line wins, with no rule applied. Whiska does not try to match a `when` to
the request — a keyword match is a worse version of what the session already does.

## Plain words, not known names

Every `use`, every fallback and every flag value must be one plain word — lowercase
letters, digits and dashes — or, in the file, null for the person's own default. Nothing
checks that it is a model Claude Code has. A misspelt name passes Whiska, and what
happens next is Claude Code's; that is the cost of not keeping the list.

The plain word is also what makes the output safe. `whiska shape` prints the flags to
start Claude with as one line — `--model opus --effort xhigh --fallback-model sonnet` —
or nothing, and every word on it was checked: the file's at build time, the command
line's on parse. So the spawn splits it with `eval "set -- $flags"`, which behaves the
same in bash and zsh (they split an unquoted variable differently), and can do nothing
but pass flags.

## Fallback is Claude Code's

`model.fallback` becomes `--fallback-model`, a comma-separated list Claude Code walks
when a model is overloaded or not available, retrying the primary at the start of each
turn. ADR-0069 recorded that Whiska cannot walk a list on a quota error, because the
error arrives after `herdr agent start` has already succeeded. That is still true, and
no longer matters: Claude Code walks it inside the session. The chain skips the chosen
model, since retrying the model that just failed is no fallback.

## What ran, not what was asked

The record keeps the model and effort the spawn asked for, and `ran_on`: the full model
id the mouse's latest turn ran on. The `Stop` hook reads it from `message.model` on the
session's own latest assistant entry in the transcript it already reads — skipping a
subagent's entries and the `<synthetic>` stamp Claude Code puts on a message no model
sent — and carries it on the doorstep entry; the owl records it on collection. So the
spawn pins no version, and the record is still exact, fallback included. `whiska mice`
shows `ran_on` once a turn has said.

## Consequences

- Migration 8 adds `effort` and `ran_on` to the mice table.
- An older `spawn-worktree` reads `whiska shape`'s output as one model alias, and would
  hand the whole line to `--model`. `whiska init` updates the repo's copy, and
  `whiska init --global` the machine's.
- Choosing a model is now the spawning session's judgment, and a judgment can be wrong.
  The catch-all is the floor: a session that skips the rules still starts the mouse on
  the catch-all's model and effort, not on nothing.
