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

## Note, 2026-09-29: a lettered decision is answered by its letter

*Rewritten 2026-10-08: this note offered the options with Claude Code's `AskUserQuestion`
picker. The note of 2026-10-08 below says why that went.*

When a delivered message ends in lettered options, they are already the last lines the
reading skills show, and the person answers in plain text. The skill relays the answer
with the fixed `whiska reply <id> "<the letter and its label>"`, or the person's own
words as written. The person still answers — this decision's line is that the model
must not compose the command out of what it read, and it does not: the command is
written out, the options come from the mouse, and the only thing composed is the reply
text out of the person's answer. Their own words go word for word, so ADR-0017 holds too.

The pointer-first rule is untouched. The message still goes out verbatim as markdown
first, in full.

## Note, 2026-09-29: `/whiska-reply` exists, and it is the only way to answer

The list at the top named `reply` from the start, but `whiska init` shipped only the two
reading skills. It does now ship `whiska-reply`, the same thin wrapper: `whiska reply
$ARGUMENTS`, or the id from the delivered line with the person's own words as the text.
Same shape as the lettered-options section already used, so there is one way to write the command.

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

## Note, 2026-09-29: a finished line offers what to do with the branch

A "finished" message has nothing to reply to, so the reading skill used to show it and
stop — and the person then typed "merge it here" by hand, every time. `whiska-delivered`
now ends its reply to a finished line with lettered options (rewritten 2026-10-08: they were
an `AskUserQuestion` picker): land here (the default), open a merge request or PR, or drop
it (amended 2026-10-07: "chat further" is gone; the person's own words are carried to the
mouse's pane from the main session. The rule that an answer goes through `whiska reply`
still holds for open questions: only a finished question gets words passed into its pane).
Unlike the mouse's lettered options above,
these options are Whiska's rather than the mouse's, which is the one thing that makes
this a different shape: they are the same few every time, written out in the skill, so
nothing is composed out of what was read.

The pick is acted on, not relayed — there is no `whiska reply` for a finished line. That
is the main session doing work on a branch, which ADR-0017 allows precisely because the
person picked it. The guard is that the options appear for a finished line and nothing
else: a branch still working, or waiting on a decision, is one nobody should merge, push
or drop. The steps themselves are not restated; `drop-worktree` and the repo's own merge
and push commands already exist, and the skill names them.

The PR option carries the finished message over as the PR body rather than composing one
from the diff, which is ADR-0032's reasoning — the branch's own session has the context to
write a real title and summary, and the main session is holding exactly what it wrote.
That ADR is still `proposed` and describes an automated flow behind a `pr: true` opt-in;
this is the manual path it says is today's behaviour ("handle PRs and merges yourself"),
with the options as the hands. Merging in the main checkout is that same sanctioned path,
so ADR-0013 is untouched: it blocks edits that bypass review, not the merge that is how
reviewed work is meant to land.

### Where the per-repo default lives: a heading, not a fifth part

A repo can name its usual choice with a line like `finish: merge here` under a `## Finish`
heading in its `CLAUDE.md`, and the options recommend that one instead. The heading is
the person's to write by hand. It is deliberately *not* a fifth part of the ADR-0045 nest.

A shipped part would mean Whiska writing a default preference into every repo it touches,
and a person wanting a different one would have to `keep` the part to change a single
line — a heavy mechanism for a one-word taste. The block's four parts all describe the
protocol, which Whiska owns; which branch-ending a person prefers is not protocol. And no
code reads the heading: the repo's `CLAUDE.md` is already in the main session's context,
so this costs one paragraph of skill text and nothing else. If it later needs to be read
by something other than the model, a part is still available.

## Addendum (2026-09-29): a command nobody runs on the person's behalf gets none

`whiska watch` ships without a skill (ADR-0051). The rule above exists so the main session
never composes bash for a command it runs for the person; the board is drawn into their
statusline, or typed by them into their own terminal, and the main session has no occasion
to run it at all.

## Note, 2026-10-06: the words replace the long names, and a finished branch lands by cherry-pick

[ADR-0079](0079-the-person-decides-what-reaches-them.md)
gives the person eight one-word commands — `inbox`, `show`, `reply`, `dismiss`, `focus`,
`away`, `hold`, `resume` — and the same eight as slash commands, each the thin wrapper this
decision asks for. They replace `/whiska-questions` and `/whiska-reply`, which `whiska
init` removes where they are plain files of Whiska's; `whiska-delivered` stays, since the
delivered line triggers it. `/inbox` wraps `whiska waiting`, a machine-wide command the
split above kept out of a session's hands: it runs only when the person types it, which is
the person asking, and its skill says so. `jump` still has none.

The finish options' first is **Land here**, by cherry-picking the branch's own
commits onto the current branch, oldest first, skipping its merges from the base, rather
than `merge --no-ff`. The `## Finish` line that names it reads `finish: land here`.

## Note, 2026-10-06: six of the words never load into a session's context

[ADR-0081](0081-rules-arrive-by-role.md) marks `inbox`, `dismiss`,
`away`, `focus`, `hold` and `resume` with `disable-model-invocation`. They are the person's
to type; their slash commands work, and no session — a mouse's included — carries their
descriptions. `show` and `reply` stay where the main session can reach them.
`whiska-delivered` keeps its two sets of finish options in files beside it, read only when
the line says finished.

## Note, 2026-10-08: no picker; options are lettered lines, read against the branch last shown

The `AskUserQuestion` picker of the 2026-09-29 notes is gone from `whiska-delivered`, its
`finished.md` and `sniff.md`, and `/show`. On 2026-10-07 the person got 28 of them and
cancelled or bypassed 13: 4 cancelled, 5 answered through "Other", 4 "chat further". A
cancel came back as "the user doesn't want to proceed", so "not yet" read as "no"; the
picker covered the message it followed; and while it was up the screen had no prompt box,
so all delivery stopped (ADR-0068). Tools that pass answers between sessions — firstmate,
no-mistakes — ask in plain text; the picker suits a tool that lives in one session.

Options are now the last lines of the reply: recommended first, then "Or write anything
else and it goes to <branch>." The person's reply is read against the branch last shown:

- Only a letter or an option's word — "A", "land", "land it" — does that option.
- "hold" runs `whiska hold <branch>` (ADR-0079); `show <id>` brings the options back.
- Anything longer is the person's own words, and goes to that branch as written, unless it
  is plainly meant for the main session.
- Two options could fit, or another 🐱 line arrived since → one line back, naming the
  branch: "feat-auth: land it, or open a PR?"
- Drop still confirms in one line.

What the picker gave — one keypress, no typos — plain letters keep. What it held by
accident, delivery, is now held on purpose: a finished line holds the slot until the
person writes something (ADR-0008, note of 2026-10-08), so "the branch last shown" is one
branch. On 2026-09-29 the person had asked for the picker "rather than a letter they have
to type back"; this reverses that, at their request.

Claude Code's own pickers — plan mode's approval, permission prompts — are outside Whiska
and still hold delivery (ADR-0068, ADR-0047).
