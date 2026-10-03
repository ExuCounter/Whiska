# The owl hoots when it delivers

Everything Whiska does to reach the person ends in one place: a line typed into the main
session's prompt box (ADR-0008). That line only works on somebody who is looking at that
terminal, and the whole reason a mouse leaves a question on the doorstep is that the person
is not — they are in another repo, another window, or away from the machine.

Until now the only thing that reached them anywhere else was a generic desktop notification
fired by a `Stop` hook after *every* turn the main session finished, mice or no mice. It was
noise in both directions: it fired when nothing had happened, and a mouse's question reached
the person only by riding along with it.

## Decision

**The owl raises one desktop notification — a hoot — at the moment it delivers a question,
from the same branch of the same function that types the line.**

Not a second mechanism watching delivery and reporting on it. The hoot is composed and sent
between `prompt` returning `:ok` and the state being returned, so there is no state in which
the line exists and the hoot does not, or the reverse. The two can never disagree about what
reached the person, because there is nothing between them to disagree in.

**Delivery, never collection.** A question that is collected and then held — behind a busy
main session, behind a half-typed prompt (ADR-0047), behind the one occupied slot — is not
on the person's screen. A hoot then would announce something they cannot go and read, and
would have to be un-announced or repeated when delivery finally happened. It hoots when it
lands, once.

**It says what the line says.** `Whiska.Delivery.Text`'s verb, pointer and count are shared
rather than copied, so there is one phrasing of one event: `🐱 whiska · feat-a needs a
decision` over `#12 · "pick one" · 2 more open`. The one thing it adds is the house, which
the line can leave out — the line is read inside a house, while a notification arrives with
no context and the person has several repos going. The one thing it leaves out is ADR-0008's
`status_unknown` caveat, which exists to explain an interruption to somebody already looking
at the terminal it interrupted.

**A finished branch hoots too, with the other sound.** `needs a decision` and `stopped
without saying why` take herdr's `request` sound; `finished` takes `done`. Giving a finished
line no hoot at all was considered and rejected: ADR-0008's note of 2026-10-01 took a
finished line out of the queue precisely so that a branch which is done is heard about
rather than sitting silent behind an unrelated question, and a silent hoot would put the
silence straight back. Two sounds is the honest answer — both arrive, one of them is the one
that must not be missed, and they are told apart without looking at the screen.

**Through herdr, over the socket it already uses.** `notification.show` is a method on the
same socket the owl already holds for `pane.get`, `pane.read` and `agent.prompt`, so it goes
behind the same boundary and is mocked the same way (ADR-0031). `osascript` and
`terminal-notifier` were rejected: one more program to shell out to, one more thing to
install, and a second notification style sitting next to herdr's own.

**Nothing new to configure.** A `hoot: true` line in `.whiska/dispatch.yml`, the shape
ADR-0032 reserves for opt-in behaviour, was considered and rejected. The switch already
exists and is herdr's: `[ui.toast] delivery` decides whether a notification appears at all,
and whether it appears as an in-app toast, a terminal notification or a system one. A second
switch in a repo's config would only ever disagree with it, and this is a machine-wide
preference about the person's attention rather than a per-repo one — the person who wants
quiet wants it in every repo at once.

## Consequences

**A hoot never costs a delivery.** The question is recorded `sent` before the hoot is
attempted, and everything the hoot can do — an error from herdr, a timeout, a raise because
the socket went away between the two calls — is swallowed. Delivery is the job; the hoot is a
courtesy. An owl that crashed on a failed notification would lose the thing the notification
was about.

**A hoot nobody sees is indistinguishable from one they did, so the owl does not try to
tell.** `notification.show` answers `:ok` whether or not anything is shown: with `[ui.toast]
delivery = "off"`, herdr accepts the call and displays nothing. Warning per delivery would be
noise, and warning on a success the owl cannot read would be a guess. Instead `whiska doctor`
reads `[ui.toast] delivery` and `[ui.sound] enabled` out of herdr's own config and says, once
and in one place, whether a delivered question will actually be heard. It is a warning and
never a failure (ADR-0038): the question is delivered either way, the line is in the main
session, and `whiska questions` still lists it. What is lost is hearing about it from across
the room. The file is the person's and machine-global, so the doctor prints what to put in it
and never writes it (ADR-0016).

**Nothing about the gate moves.** What may be delivered, when, and into which pane is exactly
ADR-0008, ADR-0047 and ADR-0044 as they stand. A hoot follows a delivery and can never cause
one; nothing here types into any pane at all.

**The `Stop`-hook notification in the person's dotfiles has nothing left to do.** It fires on
every finished turn of the main session, which is the noise this replaces, and the one event
it was carrying by accident now has its own ping. It lives outside this repo, so this ADR
records only that Whiska no longer needs it.
