# The prompt box is found by its frame, and no box on screen holds delivery

ADR-0047 made the main session's prompt box the second half of the delivery gate, and
gave `Whiska.Delivery.Draft` one rule for finding it: *the last line on the screen that
begins with `❯`*. That rule is wrong, and it had been failing closed for days.

Claude Code redraws the person's own past messages in the scrollback with the same `❯`,
at the same column. A screen captured from the live main session on 2026-10-03:

```
line 29: ❯ 🐱 feat/this-session-is-the-whiska finished · #108   <- a past message
line 41: ───────────────────────────────────────────────────
line 42: ❯                                                     <- the box, empty
line 43: ───────────────────────────────────────────────────
```

With both lines present the old rule happens to be right. Whenever the box is not drawn,
the last `❯` on the screen is the person's most recent message — which always has text in
it — so the reading came back `:typing` and the queue held, with the board saying *your
prompt box isn't empty* about a box that was not there.

A picker makes it worse. Claude Code takes the box off the screen while one is open and
marks the highlighted row with a `❯` of its own:

```
▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔
   Select model
     1. Default (recommended)  Opus 5 with 1M context
   ❯ 2. Opus (1M context) ✔    Opus 5 with 1M context
```

ADR-0047 also records `:unknown` as the honest third answer, and ADR-0008 rules that an
unavailable signal delivers rather than going silent. In practice that branch was close
to unreachable: a screen with no `❯` anywhere is rare, because the scrollback is full of
them.

## The frame is the signal, not the marker

**The box is the lowest frame on the screen that holds a prompt line, and the marker is
read only inside a frame.** Claude Code draws the box between two full-width `─` rules at
the bottom of the screen, under everything else. Nothing else on the screen has that
frame: a past message has no rule above or below it, and a rule that belongs to the
content — a diff view's own frame, a markdown horizontal rule — is indented along with
everything Claude Code prints, so starting the line is what tells the two apart. Checked
against fifteen live panes on 2026-10-03, including one split with a `git diff` view.

Neither half is enough on its own, and each is what makes the other safe. The marker
without the frame is the bug above. The frame without the marker is the mirror of it: the
lowest rule on the screen is the natural candidate for the box's bottom, and one stray
rule drawn underneath — a statusline separator — would make the box's own bottom rule the
top of a frame around the status lines, which hold no marker. Reading that as a box Whiska
cannot understand would deliver straight over the person's draft. So the frames are walked
upward until one holds a prompt line, and only running out of them is an answer.

An equal-width test on the two rules was tried instead and rejected: a full-width
separator under a full-width box is the same width by construction, so it guards against
the unlikely stray rule and not the likely one, and it turns a box that is plainly on the
screen into a permanent `:no_box` hold whenever a narrower one appears below it. Claude Code draws the box between two full-width `─` rules at
the bottom of the screen, under everything else. Nothing else on the screen has that
frame: a past message has no rule above or below it, and a rule that belongs to the
content — a diff view's own frame, a markdown horizontal rule — is indented along with
everything Claude Code prints, so starting the line is what tells the two apart. Checked
against fifteen live panes on 2026-10-03, including one split with a `git diff` view.

Position alone was considered and rejected: "the lowest `❯`" is what broke, and "the
lowest `❯` with only the status footer under it" needs a list of what the footer may
contain, which changes with every herdr statusline and Claude Code release.

**The whole of the box is read, not its first line.** A draft begun with shift+enter
leaves the marker line bare and the words on the line under it, still inside the frame.
Judging the box by its first line called that empty and typed into it — the same
destructive failure by a different route. The box is empty when every line inside the
frame is blank once the marker is taken off the one that carries it.

## The four answers

| the screen shows | reading | delivery |
|---|---|---|
| a framed box, nothing but whitespace after the marker | `:empty` | deliver |
| a framed box with anything else in it | `:typing` | hold — the person is mid-sentence |
| no frame at all | `:no_box` | **hold — there is nowhere for the line to land** |
| frames, none of them holding a prompt line | `:unknown` | deliver anyway (ADR-0008) |

`:unknown` is now reachable, and it means one thing: *something on the screen is framed
the way the box is, and no frame on it holds a prompt line*. A Claude Code that renames the marker, pads the
line, or puts something else inside the frame lands here, and ADR-0008's reasoning
applies unchanged — there is no signal, so holding would be silence.

## No box on the screen holds, which reverses a line of ADR-0047

ADR-0047 says: *"A screen with no box on it is ADR-0008's unavailable signal, and
delivers anyway. A pane scrolled away from the prompt, a `pane.read` herdr refuses, a
Claude Code that draws the marker differently — all of them read as `:unknown`."*

Two of those three keep delivering. A `pane.read` herdr refuses never reaches this code
and still delivers; a Claude Code that draws the marker differently is now `:unknown` and
still delivers. **A screen with no box on it holds.**

The reason is that it is not an unavailable signal at all. It is a clear one, and what it
says is that the session has no prompt box open — because a permission dialog or a picker
is waiting on the person, or because the pane is scrolled away from it. In the first case
delivery is not merely rude, it is destructive: `agent.prompt` types a line and presses
return, and the return goes to whatever that dialog had highlighted. The person loses the
question *and* answers something they never read.

ADR-0047's reason for delivering was that holding "would be choosing silence with no
explanation". ADR-0058 removed that: a hold says so on the board and in `whiska doctor`,
in its own words. This one says **your prompt box isn't on screen**, which is true of
every way of getting here and points at the thing the person can fix.

The risk taken on is the opposite failure: a Claude Code that stops drawing the frame
would read as `:no_box` on every screen and hold the queue indefinitely. That is the
failure ADR-0047 was guarding against, and it is accepted here because it is bounded —
it clears the moment a frame is seen again, and it has a check of its own, below — while
the failure it replaces is unbounded in the other direction: typing into an open dialog
cannot be undone by looking at a board.

## The cost, and the line that catches it

The risk taken on is named above: a Claude Code that stops drawing the frame reads as
`:no_box` on every screen and holds everything. The board says so, but the board is a
weak place to notice it — it says *held* in the same words for a hold that is working
exactly as designed.

**So `whiska doctor` gained a `prompt box` line**, and it is the only check that reads
the live main session's screen. It runs whether or not anything is queued, because a box
the gate can no longer find stops delivery before there is anything to deliver, and that
is the warning worth arriving early. It warns on the two readings that mean nothing will
be typed again — `:no_box` with the pane sitting at the bottom of its output, and
`:unknown` — and names both causes it cannot tell apart in the first, so the person reads
*either a dialog is waiting on you there, or Claude Code has changed how it draws the
box*.

A herdr that does not report the pane's scroll at all reads as sitting at the bottom, so
the check keeps warning rather than falling silent: a safeguard that a missing field
turns off is no safeguard.

It does **not** warn when the pane is scrolled up. `Whiska.Herdr.pane/2` now carries
herdr's `scroll.offset_from_bottom`, so the ordinary way to have no box on the screen —
the person reading their own scrollback — is reported as what it is and clears itself.
A check that cries wolf at someone scrolling is worse than none, which is the standard
the `session wiring` line already holds itself to.

## What is not decided here

**A dialog does not get a held reason of its own, and this is a limit rather than an
oversight.** The picker captured above draws a full-width `▔` rule where the box would
be, which is a candidate signal for *a dialog is up* specifically, and a reason of its
own would be the better message — *answer the dialog* is a different instruction from
*scroll back down*.

It is not shipped because it could only be guessed at. One captured screen is not enough
to gate on, and the two shapes that matter most — a tool permission prompt and an
`AskUserQuestion` picker — could not be captured: driving a throwaway session that far
was refused by the session's own permission classifier, and a mouse must not read another
session's pane. Whether every dialog draws that `▔` rule is therefore unverified, and a
wrong reason on the board is the failure that sent the person chasing this bug in the
first place.

Until someone captures those two screens, all three ways of having no box share one
reason, worded to be true of all of them. The work to finish it is small: confirm the
rule, add the fixtures, split `:no_box` into two readings.

## Consequences

`Whiska.Delivery.Draft.read/1` returns a fourth value, `Whiska.Watch` a fourth held
reason, `Whiska.Herdr.pane/2` a `scroll_offset`, and `whiska doctor` a `prompt box` line. Every case is a test over a screen captured from a live pane, kept verbatim under
`test/support/screens/` (ADR-0031 — the reading stays plain code over a string, testable
without herdr). Three fixtures are not verbatim, and each says so where it is used: two
are a captured screen with one line edited, because no camera can photograph a Claude
Code that does not exist yet, and the split-screen one is redrawn, because the live
screen it copies was a `git diff` of an unrelated private project.
