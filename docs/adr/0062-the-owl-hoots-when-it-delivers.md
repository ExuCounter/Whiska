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
between `prompt` returning `:ok` and the state being returned, so nothing can decide to hoot
about a question that was not delivered, or to deliver one and then decide separately whether
to hoot: there is nothing between the two to disagree in. A hoot herdr refuses still leaves
the line delivered and no hoot raised — that is the swallow below, and it is the one gap,
chosen deliberately in delivery's favour.

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

**herdr says whether it drew anything, and a delivery drops that answer.**
`notification.show` replies `{"shown": false, "reason": "disabled"}` when the person has
popups turned off, and `{"shown": true}` when it drew one — checked against herdr 0.8.2 on
the live socket. The owl therefore *can* tell, and still says nothing: somebody who turned
popups off has not asked to be told about it once per delivery, and the one place an answer
is wanted is the place the person went to ask.

**So `whiska doctor` probes rather than reads.** It sends a notification of its own and
reports what herdr says it did with it, which is both the answer and the demonstration: the
person sees the notification exactly when hoots work, and when they do not there is nothing
to see, which is the finding. Reading `[ui.toast] delivery` out of config.toml was built
first and thrown away — Whiska has no TOML parser, and a hand-rolled one read herdr's own
stock `# delivery = "off"` comment as the setting, so a person who had turned popups on was
told forever that they had not. herdr's own answer survives every config shape no regex
will. ADR-0038 already allows this: the doctor checks *and probes*, and never repairs.

It is a warning and never a failure: the question is delivered either way, the line is in
the main session, and `whiska questions` still lists it. What is lost is hearing about it
from across the room.

**The fix names an edit, never a block to paste.** `[ui.toast]` and `[ui.sound]` are both in
herdr's stock config, and a second table of either name is a duplicate key — herdr refuses
the file whole and falls back to defaults, taking the person's theme, keybindings and the
tab bar entry that draws the owl's own line (ADR-0048) with it. The config is the person's
and machine-global, so the doctor says which value to change in the table they already have
and never writes it (ADR-0016).

**A hoot shows up where the terminal never did.** The content is exactly what the line
already carries — the house, the branch, a verb, an id and the mouse's own pointer — so
nothing new is computed about the work. What is new is that it surfaces on the OS
notification centre, which on a Mac can draw on the lock screen and in a screen share. A
mouse that quotes a secret in its pointer line now quotes it there. The lever is the
person's own "show previews when unlocked" setting rather than anything in Whiska, and the
alternative — a notification that says only "a question arrived" — would cost the thing the
hoot is for, which is acting on it without opening anything.

**The title is flattened and cut.** A branch reaches the hoot from the doorstep entry a
mouse's own hook wrote, and a house name is a directory basename; neither is promised to be
one short line. The line delivery already collapses newlines out of what it types, and the
hoot does the same to its title, so a mouse cannot produce a multi-line or multi-megabyte
notification.

**Nothing about the gate moves.** What may be delivered, when, and into which pane is exactly
ADR-0008, ADR-0047 and ADR-0044 as they stand. A hoot follows a delivery and can never cause
one; nothing here types into any pane at all.

**The `Stop`-hook notification in the person's dotfiles has nothing left to do.** It fires on
every finished turn of the main session, which is the noise this replaces, and the one event
it was carrying by accident now has its own ping. It lives outside this repo, so this ADR
records only that Whiska no longer needs it.
