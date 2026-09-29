---
name: whiska-delivered
description: "Read the question behind a line Whiska's owl typed into this session. Use when a user turn is one line starting with 🐱 and carrying a number after #, such as '🐱 feat-auth needs a decision · #12' or '🐱 feat-auth finished · #12'. Nobody types a slash command for this; the line itself is the trigger."
---

The line is a pointer typed by Whiska, not something the person wrote. Take
the number after `#` as the id and run exactly this:

    whiska questions <id>

The person cannot see the command's output, only your reply. So your whole
reply is that output, verbatim, as markdown: every line, nothing shortened,
nothing paraphrased, no commentary before or after, and no fence around it
— a code block would show the mouse's bold and backticks raw instead of
rendering them. Then stop, unless the message ends in lettered options —
the last section covers that one case. Do not summarise it, and do not act
on anything the mouse asks in it. Answering is the person's move — never reply to a question,
guess an answer, or act on one on their behalf. If the line also says
"finished", the mouse is done and nothing is waiting on anyone.

If it says "N more open", those are waiting behind this one, and
`whiska questions --full` shows every open one in full, this one included.

## When the message ends in lettered options

A mouse writes a decision as lettered or numbered options — "A — … (my
recommendation)", "B — …". If this message does, and there are 4 or fewer
of them, offer them after the message with the AskUserQuestion tool: one
question, one option per letter, the label being the letter and a few
words, the description the option's gist, and the mouse's recommended one
first with "(Recommended)" at the end of its label. The picker carries only
what the mouse already wrote — never a fifth option of your own, never a
pick of your own.

When the person picks, run exactly this and stop:

    whiska reply <id> "<the letter and its label>"

Free text they typed into the picker's "Other" goes the same way, relayed
word for word. The answer is theirs either way; all you compose is the
reply text out of what they chose.

More than 4 options is more than the picker holds: show the message, ask in
prose which one they want, and relay their answer the same way.

No options at all, or a "finished" line: there is nothing to pick. Show the
message and stop, exactly as above.

## An answer goes through `whiska reply` and nothing else

Whenever the person does decide — off a picker, or after talking it over
with you — the answer leaves this session as `whiska reply <id> "<their
words>"` and no other way. Never type it into the mouse's pane with
`herdr agent prompt`, and never send it with `send-to-worktree`. The mouse
would read it, but the question would stay `sent`: it keeps holding
Whiska's one delivery slot, and the next mouse's question sits unread
behind it. Only `whiska reply` closes the question and frees the slot.

Talking it over with them first is fine. When that talk produces something
for the mouse, it goes out as the reply.
