# The owl hoots when it delivers

The owl raises one desktop notification, a hoot, at the moment it delivers a question,
from the same branch of the same function that types the line. A finished report gets a
hoot of its own as it is collected, and none when its line is typed later (ADR-0008), and
a finished branch nobody landed is reminded now and then. herdr shows each from the person's own `[ui.toast]` and
`[ui.sound]` settings; when herdr says it will not, the same hoot is raised on the desktop
instead.

## Decision

**Delivery, never collection.** A question collected and then gated, or set aside by
`away`, a focus or a hold (ADR-0079), is not on the person's screen; a hoot then would
announce something they cannot go and read. It hoots when the line lands, once.

**A finished report hoots as it is collected**, once, since its line waits until nothing
waits on the person and may land much later, or never: the branch, `finished`, its id and its pointer, with the `done` sound. Away, a focus
on another branch or a hold on its own holds that hoot until it lifts. It goes whatever
became of the branch meanwhile, a merge request or a landing included: the report is news
either way. Each report stores when it last hooted, so an owl restarted does not hoot it
again. The one exception is the first report after a review round the owl handed over
(ADR-0060) that pushed nothing: it is counted as hooted and typed, silently, since the merge request
shows nothing new to look at.

**A finished branch is reminded.** At most once per house every two hours, one hoot names
each finished branch whose last hoot is two hours old or more, with how long ago it
finished: `🐱 whiska · 2 finished, not landed`, then `no merge request: feat/a (5h),
fix/b (2h)`. A branch is named while its report is still its last word (no later
question of its mouse's, no turn started since), no merge request is recorded, it has not
landed, its worktree stands, and it has commits beyond its base, read from the main
checkout. A branch git cannot read counts as having some, since a reminder too many costs
less than work forgotten. Files a worktree has not committed are not counted: reading
them means running git in a folder the mouse writes, whose config and filters can name
programs that the owl would then run every two hours. A dead mouse's branch is still named
while its worktree stands: what waits is the work, not the mouse. Eight branches are
named at most, and the rest counted. Away silences the reminder, and one that came due
meanwhile goes on the first sweep after the person is back, within a minute. A focus
elsewhere or a hold leaves that branch out, to be named in the house's next reminder:
lifting a hold already says the branch had finished. The house's reminder clock starts
when the owl does, so a restart never reminds at once.

**It says what the line says**, sharing `Whiska.Delivery.Text`'s verb, pointer and count
rather than copying them, plus the house: the line is read inside a house, a notification
arrives with no context. `needs a decision` and `stopped without saying why` take herdr's
`request` sound; `finished` takes `done`. Both arrive, one must not be missed, and they
are told apart without looking.

**Through herdr first**, `notification.show` on the socket the owl already holds, behind
the same boundary and fake as every other herdr call (ADR-0031).

**Raised on the desktop when herdr answers `disabled` or `no_foreground_client`.** On macOS
`osascript`; on Linux `notify-send`, with the freedesktop sounds `message-new-instant` and
`complete`. Both ship with the desktop, so a hoot needs nothing installed. `rate_limited` and `busy` do not
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
quiet is the OS's own per-app notification settings for the notifier; macOS files
osascript's under Script Editor.

**A hoot never costs a delivery.** The question is recorded `sent` first; an error, a
timeout, a raise, a non-zero exit, a notifier that hangs (killed after five seconds): all
swallowed. Delivery is the job and the hoot is a courtesy.

**Somebody else's text never becomes a command.** The branch and the pointer come from a
doorstep file anything in the repo can write. The notifier runs with an argument list and
no shell; `osascript` runs a fixed script reading title and body from `argv` after a `--`
(it keeps reading options after its last `-e`, so a title of `-e` would otherwise compile
as script); `notify-send`'s arguments follow a `--` too. A NUL byte is dropped. Each branch
and house name is made one plain line, with no control or invisible character, and cut.
The reminder never runs git in a mouse's worktree, only in the main checkout. The desktop sits behind `Whiska.Desktop`, so the suite runs against a
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
- A machine with neither notifier, a server or a container, raises nothing, and the
  doctor says so in words.
- The generic `Stop`-hook notification in the person's dotfiles, which fired after every
  main-session turn, has nothing left to do.

## Considered options

- **Hoot a question on collection.** Announces what cannot yet be read, and would need
  un-announcing.
- **No hoot for a finished branch.** A branch that is done would sit silent until someone
  looked at its sidebar line.
- **Remind every finished branch, one that changed nothing included.** A branch with
  nothing to land needs no finish, and an investigation would be reminded forever.
- **One reminder hoot per branch.** Five unlanded branches would hoot five times every two
  hours.
- **Keep every hoot's time in memory.** A restarted owl would hoot every finished report
  again.
- **`hoot: true` in a repo's config.** A second switch disagreeing with herdr's.
- **Desktop notifiers only, never herdr.** A second notification style for everyone, and
  one more program to install, where herdr's own works for most.
- **`terminal-notifier` first on macOS, when installed.** Built, then dropped on
  2026-10-11: a Homebrew add-on doing what `osascript` already does, picked only on the
  machines that happen to have it, and needing a Homebrew-folder search and its own
  argument guards. What it gave, notification settings of its own apart from Script
  Editor's, is not worth a dependency on one machine's setup.

Folded in on 2026-10-08: 0071 (its text is in git history).

Changed on 2026-10-14: a finished report hoots as it is collected, never on delivery, and
a finished branch with work to land is reminded every two hours.

Changed on 2026-10-14, again: the report ending a review round that pushed nothing does
not hoot.

Changed on 2026-10-15: a finished report's line is typed again once nothing waits
(ADR-0008); its hoot stays at collection, and the line raises none.
