# A nudge is a notice typed into another house's main session

**Superseded on 2026-09-29 by [ADR-0044](0044-the-statusline-redraws-on-a-timer-not-a-typed-nudge.md).**
There is no nudge. Nothing in Whiska types into a session that is not its own house's
main session, `Whiska.Owl.Nudge` is deleted, and the statusline's elsewhere segment is
kept current by a `refreshInterval` timer on the statusLine command instead. Everything
below is what this decision said, and is history.

The short version of why: a nudge lands in the target session as a user turn, which
Claude Code cannot tell from a prompt the person typed. Each one cost that session a turn
and the model improvised on it. ADR-0044 has the full account and the arithmetic behind
the interval.


The statusline's elsewhere segment (ADR-0027) names the other project with something
waiting: `⚡ whiska waiting`. In practice it was never seen where it mattered. Claude Code
re-runs the statusline script only when that session's own conversation changes, so a
person sitting idle in one repo's main session saw a snapshot from their last keystroke,
and a question opening in another repo changed nothing on their screen until they typed.

So the owl now **nudges**: when a house gains something open that waits on the person, the
owl types one short line into the idle main session of every other open house. The line
is the smallest conversation change that forces the statusline to redraw. Its content is
secondary; the redraw is the point.

## Decision

- **A nudge is a notice, not a question.** It is never recorded in the target house,
  appears in no `whiska questions` list, awaits no answer and has nothing to close. This
  is the one deliberate exception to ADR-0009's "one delivery kind, never a notice", and
  it is scoped to cross-house only. ADR-0009 rejected a notice kind because a question
  offers a reply channel and a notice does not — reasoning about a mouse of *this* house,
  where a reply channel exists to offer. A nudge is about *another* house: the answer can
  only be given from that repo's own main session, so "look elsewhere" is all the target
  pane can usefully receive, which is precisely a notice.
- **Gated by the target's delivery slot, never holding it.** A nudge is typed only if the
  target's main pane is free by the same test a question uses (ADR-0008's table) *and* no
  question of the target's own is out waiting for an answer. Once typed it is forgotten:
  the target's next own question goes as soon as its pane is idle again. A nudge that the
  gate holds is dropped, not queued and not retried — the next keystroke in that pane
  redraws the statusline anyway. ADR-0008 carries an addendum line saying so.
- **Once per episode.** A house reports after each collection whether it has something
  open that qualifies. Only the change from nothing to something nudges; a house that stays
  open, however many questions it adds, nudges no more until it has reported nothing open
  and then something again.
- **Only what can be acted on from elsewhere qualifies:** an open or sent question that
  is `needs-decision` or unmarked. A `done` report does not nudge. It is told in its own
  house and closed once the person writes something after it (ADR-0009, ADR-0008), and from another repo it can only be
  read, which can wait.
- **The line is `⚡ <folders> waiting` and nothing else.** One repo: `⚡ whiska waiting`,
  named by its folder exactly like the elsewhere segment. If more than one source house
  has something open when a nudge goes out, one line names them all, sorted:
  `⚡ crew, whiska waiting` — never one line per repo, and never the target itself. No id,
  no path, no hint of where to read and no instruction: the line lands as a user turn in the
  target's Claude, which should have nothing to do with it beyond acknowledging.
- **No all-clear.** When the source's last open question closes, nothing is typed. An
  all-clear would double the typed turns for information nobody can act on; the stale
  segment costs one keystroke to clear.
- **Houses never call each other.** `Whiska.Owl.Nudge`, one process under the owl
  supervisor, is the only thing that reaches across houses: it takes each house's report,
  finds the other open houses through the open-houses record (ADR-0039), and asks each
  target house to run its own gate and type. A house outside an owl has nobody to tell
  and carries on.

## Consequences

- With three houses open, one question opening produces up to two extra turns in the
  other two main sessions. Each is one short line and one brief acknowledgement.
- A target that is busy, that has its own question out, or whose main pane is not running
  Claude is skipped silently. The elsewhere segment still shows the truth the next time
  that pane redraws for its own reasons.
- `CONTEXT.md` gains **Nudge**, and its Delivery entry points at it.
- ADR-0040 is taken by the `launchd` supervision work on the unmerged
  `feat/launchd-supervision` branch; this is 0041 so the two never collide on merge.

## Considered options

**Make the nudge a real question in the target house**, so ADR-0008 applies unchanged.
Rejected: it would put a whiska question in another repo's `whiska questions` that nobody
can answer there, and it would hold that house's delivery slot until closed by hand.

**Let the nudge hold the slot like a sent question.** Rejected: there is nothing to close
a nudge with, so it would need a timeout, which ADR-0037 already rejected for sent
questions.

**Nudge for `done` reports too.** Rejected: a done report is open only until its own main
pane is idle, then told and closed at once, so the nudge would usually fire for something
already gone, and the report cannot be acted on from elsewhere either way.

**A longer line with a pointer** (`… · read: whiska questions (in ~/…/whiska)`).
Rejected by the person: the line exists to redraw the statusline, and the statusline
already says where to look. Anything that reads like a command risks the target's Claude
acting on it.

## Note, 2026-09-28: the line is now also a command, and that is accepted

ADR-0043 added `whiska waiting`. The nudge's line for a single source repo named
`whiska` is `⚡ whiska waiting`, which is now literally a runnable command — exactly the
shape the "longer line with a pointer" option above was rejected for ("anything that
reads like a command risks the target's Claude acting on it").

Accepted rather than changed, for two reasons. The collision is narrow: the line is
`⚡ <folders> waiting`, so it only reads as a command when a single source repo happens
to be named `whiska`, and never for two (`⚡ crew, whiska waiting`). And the consequence
is harmless in a way the rejected option's was not: what was rejected pointed at one
specific question to read and act on, whereas `whiska waiting` is a read-only listing
that changes nothing. A target session that runs it has done no damage and told itself
something true.

The decision above is unchanged — the line stays `⚡ <folders> waiting` and nothing else.
This note exists so the next reader knows the overlap was seen rather than missed.
