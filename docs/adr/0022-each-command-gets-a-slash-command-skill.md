# Each command gets a slash-command skill, not model-composed bash

Most Whiska commands are meant to be used by your main Claude session on your behalf —
`questions`, `reply`, `diff`, `mice`, `quiet`, `loud`, `reopen`, `cleanup` — all natural to
ask for in plain conversation. Relying on the model to translate plain English into the
right Bash call every time is exactly the failure mode the worktree-relay fix already
taught us to avoid: less surface for the model to get wrong or forget.

So `whiska init` also installs a matching Claude Code skill per command in
`.claude/skills/` — real slash commands (`/whiska-questions`, `/whiska-reply`, ...),
discoverable via `/help`. Each skill is a thin wrapper that runs the fixed `whiska`
command and nothing more.

## Consequences

Which commands belong to whom is drawn by one fact: `whiska start` *creates* the Claude
session, so it cannot be something Claude runs for you. That splits the surface three ways
— typed by you before a session exists (`init`, `start`, `stop`, `doctor`, `update`), used
by your session once one is running (the list above), and machine-wide with no "right repo"
to run them in (`projects`, `goto`).

## Note, 2026-09-28: one skill is triggered by a line, not a slash command

`whiska-delivered` is installed alongside the per-command skills but nobody types it.
The owl's delivered line (`🐱 <branch> <verb> · #<id> …`) no longer carries `read:` or
`answer:` commands, so the main session's Claude has to know what to do when one lands
as a user turn. The skill's description names that shape, so Claude Code picks it by
description; its body is the same thin wrapper — run `whiska questions <id>`, show the
output, stop, never answer on the person's behalf. Same reasoning as above: the model is
not asked to compose the read from a hint in the line.

## Note, 2026-09-28: a wrapper may run one of two fixed commands

`whiska-questions` now runs `whiska questions --full` when nobody passes an
argument, and `whiska questions $ARGUMENTS` when somebody passes an id. Two
fixed commands, chosen by whether `$ARGUMENTS` is empty, is still the thin
wrapper this decision asks for: what a wrapper must not do is compose a command
out of what it read, summarise the output, or answer on the person's behalf
(ADR-0017). Picking between two written-out commands on one written-out
condition is none of those.

The reason for `--full` is the same one that moved the commands out of the
delivered line: the person ran `/whiska-questions`, was told "read either in
full with `whiska questions 1` or `whiska questions 3`", and had to read an id
off a list and type it back. Now the default prints everything open in full, so
there is no id to type; an id still reads exactly one.

## Note, 2026-09-29: a lettered decision is offered as a picker

When a delivered message ends in 2–4 lettered options, the reading skills offer them
with Claude Code's own `AskUserQuestion` tool after showing the message, then relay the
pick with the fixed `whiska reply <id> "<the letter and its label>"`. The person still
answers — this decision's line is that the model must not compose the command out of
what it read, and it does not: the command is written out, the options come from the
mouse, and the only thing composed is the reply text out of the person's pick. Free
text typed into the picker's "Other" is relayed word for word, so ADR-0017 holds too.

The pointer-first rule is untouched. The message still goes out verbatim as markdown
first, in full; the picker comes after it and adds nothing to it. More than four options
is beyond what the tool takes, so the skill asks in prose instead of quietly dropping
some.

## Note, 2026-09-29: `/whiska-reply` exists, and it is the only way to answer

The list at the top named `reply` from the start, but `whiska init` shipped only the two
reading skills. It does now ship `whiska-reply`, the same thin wrapper: `whiska reply
$ARGUMENTS`, or the id from the delivered line with the person's own words as the text.
Same shape as the picker section already used, so there is one way to write the command.

Both it and `whiska-delivered` now say what the reading skills only implied: an answer to
a mouse goes through `whiska reply <id>` and nothing else — never `herdr agent prompt`
into the mouse's pane, never `send-to-worktree`, which is for a new idea rather than for
something a mouse is already waiting on. The CLAUDE.md block's delivery part (ADR-0045)
says it too, for the main session.

The reason is ADR-0008's one delivery slot. Text typed into a mouse's pane reaches the
mouse, but the question stays `sent`: it keeps the slot, and the next mouse's question
sits `open` behind it until something supersedes it. That happened on 2026-09-29 and cost
six minutes of a question nobody could see — the same root cause as the ghost slot fixed
earlier that day. Only `whiska reply` closes the question and frees the slot.

A `PreToolUse` guard was considered and rejected. The hook does run in the main session —
ADR-0013's rule aims at it — but it cannot tell an answer from a new idea: `herdr agent
prompt` into a live mouse's pane is exactly what `send-to-worktree` does legitimately
(ADR-0046), open question or not. Denying it would break that, and the decision would
have to read the questions table, which no rule does today. So this one stays judgment in
`CLAUDE.md` and in the skills, which is the split ADR-0010 draws.
