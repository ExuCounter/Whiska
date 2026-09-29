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
