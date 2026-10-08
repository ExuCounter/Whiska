# The owl hoots when it delivers

The owl raises one desktop notification, a hoot, at the moment it delivers a question,
from the same branch of the same function that types the line. herdr shows it from the
person's own `[ui.toast]` and `[ui.sound]` settings; when herdr says it will not, the same
hoot is raised on the desktop instead.

## Decision

**Delivery, never collection.** A question collected and then gated, or set aside by
`away`, a focus or a hold (ADR-0079), is not on the person's screen; a hoot then would
announce something they cannot go and read. It hoots when the line lands, once.

**It says what the line says**, sharing `Whiska.Delivery.Text`'s verb, pointer and count
rather than copying them, plus the house: the line is read inside a house, a notification
arrives with no context. `needs a decision` and `stopped without saying why` take herdr's
`request` sound; `finished` takes `done`. Both arrive, one must not be missed, and they
are told apart without looking.

**Through herdr first**, `notification.show` on the socket the owl already holds, behind
the same boundary and fake as every other herdr call (ADR-0031).

**Raised on the desktop when herdr answers `disabled` or `no_foreground_client`.** On macOS
`terminal-notifier` when installed, else `osascript`; on Linux `notify-send`, with the
freedesktop sounds `message-new-instant` and `complete`. `rate_limited` and `busy` do not
fall back: that is herdr pacing itself. An error does not: herdr may have drawn the hoot
before it. A reason herdr adds later does not, until decided here; the doctor names it.
The reason the fallback exists: `[ui.toast] delivery` is one switch over two decisions,
herdr's own toast for every agent and every explicit `notification.show`, with no
per-source filter and no override (checked against herdr, 2026-10-04). A person who turns
toasts off to silence a toast per background mouse has also, without choosing to, silenced
the one notification Whiska raises for them.

**No setting, either way.** herdr's switch is the person's machine-wide preference about
their attention, and a per-repo switch would only ever disagree with it. A switch for the
fallback would be a second way back to the silence the fallback removes. The lever for
quiet is the OS's own per-app notification settings for the notifier.

**A hoot never costs a delivery.** The question is recorded `sent` first; an error, a
timeout, a raise, a non-zero exit, a notifier that hangs (killed after five seconds): all
swallowed. Delivery is the job and the hoot is a courtesy.

**Somebody else's text never becomes a command.** The branch and the pointer come from a
doorstep file anything in the repo can write. The notifier runs with an argument list and
no shell; `osascript` runs a fixed script reading title and body from `argv` after a `--`
(it keeps reading options after its last `-e`, so a title of `-e` would otherwise compile
as script); `notify-send`'s arguments follow a `--` too. A NUL byte is dropped. A leading
`-`, `(`, `{`, `<` or quote gets a zero-width space in front of it, since terminal-notifier
would read it as an option or a property list. The title is flattened to one line and cut.
A notifier off launchd's bare PATH is looked for in `/opt/homebrew/bin` and
`/usr/local/bin`. The desktop sits behind `Whiska.Desktop`, so the suite runs against a
stand-in; one test tagged `live_desktop` reaches the real one when asked.

**`whiska doctor` probes rather than reads.** It sends a hoot down the same function and
reports what herdr did with it and which notifier raised it, so the person sees the
notification exactly when hoots work. Reading `[ui.toast]` out of config.toml was built and
thrown away: a hand-rolled parser read herdr's stock `# delivery = "off"` comment as the
setting. A warning, never a failure (ADR-0038). The fix names a value to change in the
table the person already has, never a block to paste: a second `[ui.toast]` table is a
duplicate key, and herdr refuses the whole file, theme, keybindings and tab bar entry
included. A notifier's exit 0 means the notification reached the OS, so when nothing
appears the doctor points at the desktop's own settings or a missing notification server.

## Consequences

- Two notification styles can appear on one machine, never for the same hoot.
- The pointer line surfaces on the notification centre, lock screen and screen share
  included; the person's "show previews" setting is the lever. A hoot that said only "a
  question arrived" would cost the thing it is for, acting without opening anything.
- A machine with none of the three notifiers, a server or a container, raises nothing,
  and the doctor says so in words.
- The generic `Stop`-hook notification in the person's dotfiles, which fired after every
  main-session turn, has nothing left to do.

## Considered options

- **Hoot on collection.** Announces what cannot yet be read, and would need un-announcing.
- **No hoot for a finished branch.** A branch that is done would sit silent behind an
  unrelated question.
- **`hoot: true` in a repo's config.** A second switch disagreeing with herdr's.
- **Desktop notifiers only, never herdr.** A second notification style for everyone, and
  one more program to install, where herdr's own works for most.

Folded in on 2026-10-08: 0071 (its text is in git history).
