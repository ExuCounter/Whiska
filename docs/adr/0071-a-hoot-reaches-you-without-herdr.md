# A hoot herdr will not show is raised on the desktop

Amends ADR-0062. Its rule stands and is restated here because this record leans on it:
**the hoot goes out from the same place as the typed line, so the two can never disagree.**
What changes is what happens after herdr answers.

## What changed

ADR-0062 sent the hoot through herdr and nothing else. It rejected `osascript` and
`terminal-notifier` as one more program and a second notification style, rejected a Whiska
setting because "the switch already exists and is herdr's", and dropped herdr's answer on
delivery because "somebody who turned popups off has not asked to be told about it once per
delivery".

All three rest on one assumption: that `[ui.toast] delivery` is one decision, the person's
decision about notifications. It is not. It is one switch over two decisions. Checked against
herdr on 2026-10-04: the same setting gates herdr's own automatic toast for every agent and
every explicit `notification.show` call. `delivery = "off"` makes `notification.show` reply
`{"shown": false, "reason": "disabled"}`. There is no per-workspace or per-source filter, and
`notification.show` has no override flag. `[ui.sound.agents]` filters by agent kind only, and
every mouse is kind `claude` exactly like the main session, so it cannot separate them either.

So a person who turns herdr's toasts off to stop a toast for every background mouse has also,
without choosing to, silenced the one notification Whiska raises for them. ADR-0062's call was
reasonable on what was known: it took one switch to mean one decision. The fact that moved is
that it does not.

## Decision

**When herdr says it did not show a hoot because its popups are off or nobody is attached,
Whiska raises the same hoot on the desktop itself.** On macOS that is `terminal-notifier` when
it is installed, falling back to `osascript`.

**Which of herdr's reasons fall back.** herdr's reasons are `disabled`, `rate_limited`,
`no_foreground_client` and `busy`.

- `disabled` falls back. That is the case above.
- `no_foreground_client` falls back. No herdr client is attached, which means the person is
  away from herdr, which is exactly when the hoot is the only thing that reaches them.
- `rate_limited` and `busy` do not. They are herdr pacing itself, and raising the hoot around
  them would defeat the pacing.
- An error from herdr does not. herdr may have drawn the hoot before the error, and two of one
  event is worse than one.
- A reason herdr adds later does not, until it is decided here. `whiska doctor` names it.

**Always on, with no setting.** The point of the change is that a hoot nobody sees is a
silent failure. A switch to turn the fallback off would be a second way to reach the silence
this removes. ADR-0062's "nothing new to configure" therefore still holds.

**Decided in the same place as the typed line.** `Whiska.Delivery.Hoot.send_out/4` asks herdr,
reads its answer and, on a reason that falls back, raises the same composed hoot on the
desktop. The house calls it from the branch that has just typed the line, exactly where it
called herdr before. Nothing hoots on the desktop for a question that was not delivered, and
nothing decides separately whether to. `whiska doctor` probes through the same function, so
what it reports is what a delivery does.

**Somebody else's text never becomes a command.** The branch and the pointer line come from a
doorstep file that anything in the repo can write. The notifier runs with an argument list and
no shell. `osascript` runs a fixed script that reads the title and body from `argv`, and they
follow a `--`: osascript keeps reading options after its last `-e`, so without it a title of
exactly `-e` would be compiled as more script, and a `property` initialiser in the body would
run a shell command. A NUL byte, which no argument can carry, is dropped. A leading `-`, `(`,
`{`, `<` or quote, after any whitespace, which terminal-notifier's argument parsing would read
as an option or a property list, gets a zero-width space in front of it. The tests run a branch
name with quotes, backticks, a semicolon and `$(…)` through a real process and read back each
argument byte for byte. They also hand the real `osascript` a title of `-e`, and check that it
comes back as data.

**Found where Homebrew puts it.** The owl runs under launchd, whose PATH is
`/usr/bin:/bin:/usr/sbin:/sbin`. A notifier not on PATH is also looked for in
`/opt/homebrew/bin` and `/usr/local/bin`, so the owl and `whiska doctor` run from a shell pick
the same program.

**It sits behind its own boundary**, `Whiska.Desktop`, for the reason herdr does (ADR-0031):
the suite runs against a stand-in with no notifier. Nothing appears on the screen of whoever
runs the tests, except in the one test tagged `live_desktop`, which runs only when asked for.

## Consequences

**Where there is no notifier, nothing is raised, quietly.** On Linux, or on a Mac without
`osascript`, the desktop answers `{:error, :no_notifier}` and the delivery carries on as
before. `whiska doctor` says so in words: herdr did not show it, there is no terminal-notifier
or osascript to raise it instead, so a delivered question is silent. It is a warning, never a
failure (ADR-0038), and the fix is still the edit to herdr's own table.

**A notifier never costs a delivery.** Whatever the desktop does — a non-zero exit, a raise, a
hang — comes back as an answer and is dropped, as herdr's is. A notifier that has not returned
after five seconds is killed, because the house runs it inline.

**The doctor's "ok" is the notifier's exit, not the screen.** A notifier that exits 0 has
handed the notification to macOS. If macOS has notifications off for `terminal-notifier` or
Script Editor, nothing appears, so the check says that is where to look. The herdr fix it
names, `delivery = "system"`, is offered only for `disabled`: nothing in herdr's config
attaches a client.

**Two notification styles can now appear, but never for the same hoot.** One comes from herdr
when its popups are on, the other from the desktop when they are off. This is the cost ADR-0062
named and rejected. It is accepted here because the alternative is no hoot at all for anyone
who silences herdr's per-agent noise.

**The person who wants Whiska quiet has no switch for it here.** macOS's own per-app
notification settings for `terminal-notifier` or Script Editor (`osascript`) still apply, and
that is the lever.

## Note, 2026-10-05: Linux raises it with notify-send

The "nothing is raised" consequence above was Linux's. Since
ADR-0077 made Linux a supported platform,
a hoot herdr will not show is raised there with `notify-send`, tried after
`terminal-notifier` and `osascript`. Its title and body follow a `--`, which ends
notify-send's option parsing, so a title of `-e` is still data. Its sound is the
freedesktop name for the event: `message-new-instant` for a question, `complete` for a
finished branch. `{:error, :no_notifier}` now means a machine with none of the three: a
server or a container. The doctor names all three. When `notify-send` exits 0 but nothing
appears, the doctor points at the desktop's own notification settings or a missing
notification server, rather than at macOS.

The same change fixed a race the Linux run turned up. A notifier that exited before its
pid could be read raised inside the notifier and came back as an error. The pid is now
read only when the deadline passes, which is the only time it is needed.
