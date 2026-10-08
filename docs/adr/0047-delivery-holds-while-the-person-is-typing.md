# Delivery holds while the person is typing, read off the prompt box's frame

"Idle" reaches Whiska from Claude Code's `Stop` hook by way of herdr, and it means one
thing: the model is not working. It says nothing about the person. A half-typed prompt sits
in the box while the pane is every bit as idle, and `agent.prompt` types into that box, so
the owl's line would land inside the draft or submit it. So the gate (ADR-0008) has a
second half: **the main session's prompt box must be empty.** A box with a draft in it
holds the question, still `open` and first in the queue, until the next trigger finds the
box clear; at worst the backstop, so a minute late.

The box is read off the screen because herdr has no other signal. No field on `pane.get` or
`agent.get` records a keystroke and no event announces one. herdr's `focused` was
rejected: the person sitting in the main session is exactly when a question is welcome, and
a main pane left focused all day would hold the queue indefinitely. Mice are never
screen-read; only the main session is, once per delivery attempt.

## The frame is the signal, not the marker

**The box is the lowest frame on the screen that holds a prompt line, and the marker is
read only inside a frame.** Claude Code draws the box between two full-width `─` rules at
column 0, under everything else. Nothing else on the screen has that frame: a past message
has no rule above or below it, and a rule that belongs to content, a diff view's frame or
a markdown rule, is indented with everything Claude Code prints.

Neither half is enough alone. The marker alone is wrong: Claude Code redraws the person's
past messages in the scrollback with the same `❯` at the same column, so whenever the box
was off the screen "the last line beginning with `❯`" found a past message, which always
has text in it, and the gate held delivery for days saying the box was not empty. A picker
marks its highlighted row with a `❯` of its own. The frame alone is wrong the other way: a
stray rule drawn under the box, a statusline separator, would make the box's bottom rule
the top of a frame around the status lines, which hold no marker, and reading that as a
box Whiska cannot understand would deliver over the draft. So the frames are walked upward
until one holds a prompt line, and only running out of them is an answer.

**The whole of the box is read, not its first line.** A draft begun with shift+enter
leaves the marker line bare and the words on the line under it. The box is empty when
every line inside the frame is blank once the marker is taken off the one that carries it.

**Faint text in the box is Claude Code's, not the person's.** After a reply, Claude Code
offers the next prompt inside the empty box, and a fresh session shows a placeholder, both
as plain words after the marker. The screen is therefore read with its escapes
(`format: "ansi"`), the frame is found on the text with the escapes taken out, and the box
is empty when everything inside it that is not faint (SGR 2) is whitespace:

| what is in the box | how the line after `❯` is drawn |
|---|---|
| a suggested next prompt, or the fresh-session placeholder | `ESC[2m` text `ESC[0m`, faint |
| a typed line, or a `[Pasted text]` chip | no style at all |
| nothing | the marker and a non-breaking space |

Faint rather than a colour, because past messages are drawn in explicit greys that move
with the theme and faint does not. An unrecognised style counts as text, so a theme or
release that draws its ghost text some other way falls to holding, which the sidebar line
explains, never to typing over a draft.

## The four answers

| the screen shows | reading | delivery |
|---|---|---|
| a framed box, nothing but whitespace after the marker | `:empty` | deliver |
| a framed box with anything else in it | `:typing` | hold: the person is mid-sentence |
| no frame at all | `:no_box` | **hold: there is nowhere for the line to land** |
| frames, none holding a prompt line | `:unknown` | deliver anyway (ADR-0008) |

**No box on the screen holds**, for a different reason than a draft. It is not an
unavailable signal; it says the session has no prompt box open, because a permission
dialog or a picker is waiting on the person, or the pane is scrolled away from it. In the
first case delivering is destructive: `agent.prompt` types the line and presses return,
and the return goes to whatever the dialog had highlighted, so the person answers something
they never read and loses the question with it. The hold says `your prompt box isn't on
screen`, true of every way of getting here. The risk taken on is a Claude Code that stops
drawing the frame, which would hold everything; it is bounded, clears the moment a frame
is seen, and has a check of its own below.

`:unknown` means something on the screen is framed the way the box is and no frame holds a
prompt line. There is no signal, so holding would be silence. A `pane.read` herdr refuses
never reaches the reading and delivers.

Delivery and pickup (ADR-0067) both type into a box, and `Whiska.Delivery.Draft.hold/1`
turns a reading into hold or go for both, so they cannot drift.

## The check that catches the cost

`whiska doctor`'s `prompt box` line is the only check that reads the live main session's
screen. It runs whether or not anything is queued, because a box the gate cannot find
stops delivery before there is anything to deliver. It warns on `:no_box` with the pane at
the bottom of its output, naming both causes it cannot tell apart (a dialog waiting, or
Claude Code drawing the box differently), and on `:unknown`. A pane the person has scrolled
up in is reported as that and clears itself: herdr's `scroll.offset_from_bottom` says so,
and a herdr that does not report scroll reads as at the bottom, so a missing field never
turns the safeguard off.

## Considered options

- **An equal-width test on the two rules.** Rejected: a full-width separator under a
  full-width box is the same width by construction, and a narrower one below turns a box
  plainly on screen into a permanent hold.
- **Position alone**, the lowest `❯` with only the status footer under it. Rejected: it
  needs a list of what the footer may contain, which changes with every release.
- **The cursor position** as the draft signal. Not available: herdr 0.8.2 reports none.
- **A ghost-text rule relative to the marker's colour.** Rejected by the captures: the
  marker carries no style and its ghost text is faint.
- **A dialog reason of its own.** Not shipped: the picker draws a `▔` rule where the box
  would be, but a permission prompt and an `AskUserQuestion` picker could not be captured,
  so whether every dialog draws it is unverified. All three ways of having no box share one
  reason worded to be true of all of them.

## Consequences

- `Whiska.Herdr.read_screen/2` returns the text and judges nothing; `Whiska.Delivery.Draft`
  judges the text and talks to nothing (ADR-0031). When Claude Code changes how it draws
  the box, one function is wrong and its tests say so.
- Every reading is a test over a screen captured from a live pane, kept under
  `test/support/screens/`; the few edited or redrawn fixtures say so where they are used.
- A hold is never silent: the main checkout's sidebar line says `gated` with the reason
  once it has lasted ten seconds (ADR-0082), and `whiska doctor` says it whenever asked.

Folded in on 2026-10-08: 0068 (its text is in git history).
