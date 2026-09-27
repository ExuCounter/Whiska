# The bash relay is gone; the cutover was hard, and the gap is accepted

**This decision was reversed on 2026-09-27 and rewritten in place.** What it said before:

> Whiska controls real things — edits and pushes. Proving it out while today's bash
> wake-queue system is still in place as a fallback is safer than switching all at once.
> Both systems run together for a while. The old relay is not removed as part of shipping
> Whiska; retiring it is a separate, later decision made once Whiska has actually earned
> it.

That later decision has now been made, earlier than the original reasoning expected and
against its recommendation. The relay — `bin/herdr-worktree-wake.sh`, the
`herdr-worktree-notify.sh` `Stop` hook, the `herdr-worktree-resume.sh` `SessionStart`
hook, their tests and their wiring — was deleted from the dotfiles repo while the owl's
delivery slice was still unwritten.

## Why, and what it costs

The original argument was about safety through overlap: keep a working fallback while the
replacement proves itself. The counter-argument that won is that overlap has its own
cost. Two systems watching the same `[worktree-status: ...]` marker means two things to
keep in step, and the relay's own delivery path — a queue file, a lock directory, a
relay-file convention, a retry ladder — is precisely the surface the owl exists to
replace. Carrying both while designing the second invites the second to be shaped by the
first.

**The cost is real and was accepted knowingly: nothing notifies the main session today.**
The owl collects a mouse's question off the doorstep and files it in the house, which is
durable and loses nothing (ADR-0036, ADR-0007). But delivery — the idle-gated queue of
ADR-0008, actually putting a question in front of the person — does not exist yet. Until
it does, a worktree that finishes or asks something is silent, and the person has to go
and look: `ls .git/whiska/doorstep/*.json`, or the house.

**Durability was never the thing at risk**, which is what makes the gap tolerable rather
than reckless. The `Stop` hook writes to the doorstep unconditionally, so no question is
lost while delivery is missing — they queue up on disk exactly as they would if the owl
were merely down. What is lost is the interruption, not the content.

**There is no fallback to fall back to.** If the owl's collection turns out to be wrong,
the recovery is to fix it, not to re-enable the relay. That is the property this decision
gave up, and it is the reason the original ADR argued the other way.

## Consequences

Delivery is now the critical path rather than one slice among several: every worktree
interaction is degraded until it lands. The dotfiles instructions were updated in the
same change to stop promising a notification that no longer arrives — the
`spawn-worktree` and `send-to-worktree` skills, and the "Worktree status marker" rule in
the global `CLAUDE.md`.

**The marker itself survives and matters more.** `Whiska.Question.Marker` parses exactly
the string the relay used to grep for, so the convention is unchanged; only the transport
is gone. A worktree's whole final message is what gets stored, so writing the full
content in the response body — not compressing it into the marker — is now the only thing
that makes a question answerable later.
