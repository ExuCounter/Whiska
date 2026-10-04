# Delivery holds while the person is typing

ADR-0008 gates delivery on the main session being idle. "Idle" reaches Whiska from
Claude Code's `Stop` hook, by way of herdr, and it means one thing: the model is not
working. It says nothing about the person. A half-typed prompt sits in the input box
while the pane is every bit as idle, and `agent.prompt` types into that box — so the
owl's line lands inside the person's draft, or submits it. Either way the person loses
what they were writing and Claude Code answers something nobody wrote.

**The gate grows a second half: the box must also be empty.** When it is not, the
question is *held* — still `open`, still first in the queue, delivered on the next
trigger once the box clears (ADR-0008's queue semantics, ADR-0007's nothing is lost).
The worst case is the backstop, so a held question is at most a minute late.

## The signal is the screen, because herdr has no other

Checked against herdr 0.8.2 on 2026-09-29, the live socket and `herdr api schema`:

- **No input signal.** No field on `pane.get` or `agent.get` records a last keystroke or
  a last input time. No event announces one: the three per-pane subscriptions are
  `pane.output_matched`, `pane.agent_status_changed` and `pane.scroll_changed`, and no
  global event is about input either. There is nothing to hold on.
- **`focused` exists and was rejected.** herdr does report which pane the person is
  looking at, and it is reliable. But the person sitting in the main session is exactly
  when a question is most welcome, and a main pane left focused all day would hold the
  queue indefinitely. It answers a question we are not asking.
- **The screen shows the box.** `pane.read` with `source: "visible"` returns the
  viewport as plain text, and Claude Code's prompt box is in it: `❯` and a non-breaking
  space, then whatever has been typed. An empty box is the marker and nothing else. This
  was verified against a live pane — empty, one word, a multi-line draft, and a
  `[Pasted text #5 +8 lines]` chip — and against the person's own main session, which was
  mid-sentence at the time.

Reading the screen is a worse kind of signal than a hook, and ADR-0008 says as much
approvingly. It is taken here because the alternative is not a better signal, it is no
signal — and the failure it prevents is the loudest one Whiska has.

## The spec rejected screen reading, for a different job

`specs/spec.md`, under "Knowing what a mouse is doing": *"This also replaces the earlier
plan to read each pane's visible screen content directly — that would've needed a
separate, unverified code path just for this. The hook data is already flowing for
enforcement, so this is free."*

That rejection stands, and this decision does not reopen it. It is about a different
subject and a different job: every *mouse* pane, read continuously, to turn into an
activity phrase — and it was rejected because a signal for that was already flowing from
`PreToolUse` for nothing. Here the subject is the *main session*, the read happens once
per delivery attempt, and no hook carries what is needed: Claude Code has no event for
the person typing, and herdr forwards none. The spec's own reason for saying no — there
is a free signal already — is exactly what is missing, so the answer comes out the other
way. Mice are still never screen-read.

## Consequences

The guesswork is confined. `Whiska.Herdr` gains one callback, `read_screen/2`, which
returns the text and judges nothing; `Whiska.Delivery.Draft` judges the text and talks to
nothing (ADR-0031). When Claude Code changes how it draws the box, one function is wrong
and its tests say so.

**A screen with no box on it is ADR-0008's unavailable signal, and delivers anyway.** A
pane scrolled away from the prompt, a `pane.read` herdr refuses, a Claude Code that draws
the marker differently — all of them read as `:unknown`, and holding on `:unknown` would
be choosing silence with no explanation, which is the reasoning ADR-0008 already settled
for `agent_status: "unknown"`.

**Being held is never silent.** `whiska doctor`'s questions line says
`N open, held: person is typing`. That is the check that catches the failure this design
can have — a box Whiska reads as occupied when it is not, holding the queue forever.

## Amendment, 2026-10-03: no box on the screen holds (ADR-0068)

Two things above are wrong and are corrected here rather than in a superseding decision,
because the gate itself stands: the box must still be empty, and the screen is still the
only place to read it from.

**Finding the box.** "The last line that begins with `❯`" is not the box. Claude Code
redraws the person's own past messages with the same marker at the same column, so
whenever the box was not on the screen the rule found a message — and a message always
has text in it. The gate failed closed to `:typing` and held delivery, saying *your
prompt box isn't empty* about a box that was not there. The box is now found by its
frame, the pair of horizontal rules at column 0 that nothing else on the screen has, and
the marker is read only inside it.

**The dialog case is what made the paragraph above wrong.** It lists "a pane scrolled
away from the prompt" and stops there, and on that case it was right. The case it does
not name is a permission prompt or a picker: Claude Code takes the box off the screen
while one is open, and the session cannot accept a typed line at all. Delivering then is
not a slightly rude interruption, which is what this paragraph weighed. `agent.prompt`
types the line *and presses return*, and the return goes to whatever the dialog had
highlighted — so the person answers something they never read, and loses the question
with it. That is unrecoverable, and no board can undo it.

**So a screen with no box on it holds**, under its own reason — *your prompt box isn't on
screen* — true of the dialog, of the scrolled-away pane, and of a Claude Code that has
stopped drawing a frame. The reason given above for delivering was that holding "would be
choosing silence with no explanation"; ADR-0058 ended that, and a hold now says itself on
the board and in `whiska doctor`. The other two cases still deliver: a `pane.read` herdr
refuses never reaches the reading, and a frame whose contents cannot be read is
`:unknown`, which is ADR-0008's unavailable signal and genuinely reachable now.

`whiska doctor` grew a `prompt box` line for the cost that comes with this: a Claude Code
that changes its frame would read as no box on every screen and hold everything. That
line reads the live main session's screen whether or not anything is queued, and warns
when there is no box and the pane is not scrolled away from one.

ADR-0068 has the captured screens and the full reasoning.

## Amendment, 2026-10-04: the screen is read with its styling (ADR-0068)

*"`pane.read` with `source: "visible"` returns the viewport as plain text … An empty box
is the marker and nothing else"* is no longer how the box is read. Claude Code draws its
own suggested next prompt, and a fresh session's placeholder, as faint text inside an
empty box, and as plain text that is a line of words the person never typed. The screen
is now read with its escapes, and faint text inside the box does not count as a draft.
`read_screen/2` still judges nothing. ADR-0068's amendment of the same date has the
captures and the reasoning.
