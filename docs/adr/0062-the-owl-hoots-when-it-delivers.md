# The owl hoots when it delivers

The owl raises one desktop notification, a hoot, at the moment it delivers a question,
from the same branch of the same function that types the line. A finished report gets a
hoot of its own as it is collected, and none when its line is typed later (ADR-0008), and
a finished branch nobody landed is reminded now and then. Each is raised on the desktop
directly, never through herdr, right away and on its own, with a click that jumps to the
main session.

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

**The desktop directly, never herdr.** Each hoot is raised by `Whiska.Desktop`, which sits
behind a behaviour so the suite runs against a stand-in (ADR-0031's reasoning); one test
tagged `live_desktop` reaches the real one when asked. herdr's `[ui.toast] delivery` is one
switch over two decisions: herdr's own agent toasts, for every background workspace, and
every `notification.show`. It has no per-pane or per-workspace filter, and
`[ui.sound.agents]` filters by agent kind only, which a main session and a mouse share
(checked against herdr 0.9.3, 2026-10-15). So herdr's toasts on would announce every mouse,
which the person does not want, and off, `notification.show` still answers `shown: true`
and draws nothing: all 61 hoots of 2026-10-15 were lost that way, and the earlier rule of
falling back to the desktop only on `disabled` or `no_foreground_client` never fired. Whiska
is therefore the only source of notifications, and only for what waits on the person in a
main session; herdr's popups stay off in the person's `herdr.toml`.

**A click jumps.** On macOS `terminal-notifier` raises the hoot when it is installed,
since it alone carries a click that runs a command: `whiska jump` on the house's main
checkout, with the owl's own `escript` and `whiska` paths, because a click runs with almost
no `PATH`, and kitty brought forward while it is running, with no setting for either. Without
it, or when it fails, `osascript`, which ships with macOS, raises the hoot with no click; on Linux `notify-send`,
with the freedesktop sounds `message-new-instant` and `complete`, also with no click.

**Each hoot stays.** No grouping, no hold, no replacing an earlier notification: each arrives
at once and stays beside the others, so the person sees where to jump. That it stays on
screen until acted on is macOS's per-app *Alerts* style for terminal-notifier, set in System
Settings › Notifications; the files that hold it are unreadable to the owl, so the doctor says
what to set rather than detecting it.

**No setting.** A per-repo switch would only ever disagree with the person's machine-wide
preference about their attention. The lever for quiet is the OS's own per-app notification
settings for the notifier; macOS files `terminal-notifier`'s under its own name and
osascript's under Script Editor.

**A hoot never costs a delivery.** The question is recorded `sent` first; an error, a
timeout, a raise, a non-zero exit, a notifier that hangs (killed after five seconds): all
swallowed. Delivery is the job and the hoot is a courtesy.

**Somebody else's text never becomes a command.** The branch and the pointer come from a
doorstep file anything in the repo can write. The notifier runs with an argument list and
no shell; `osascript` runs a fixed script reading title and body from `argv` after a `--`
(it keeps reading options after its last `-e`, so a title of `-e` would otherwise compile
as script); `notify-send`'s arguments follow a `--` too. `terminal-notifier` reads each
value as a property list, so a title or text starting with `(`, `{` or `<` never makes it
return (checked against 2.0.0): such a value gets an invisible zero-width space in front.
Its click is a shell string, so each path in it is single-quoted, a quote inside closed,
escaped and reopened. A NUL byte is dropped. Each branch
and house name is made one plain line, with no control or invisible character, and cut.
The reminder never runs git in a mouse's worktree, only in the main checkout.

**The owl logs each hoot.** One line in `owl.log` per hoot: its title and the notifier that
raised it, or why none did. A notifier's exit 0 means the notification reached the OS, so the
log shows what Whiska did and nothing more.

**`whiska doctor` probes rather than reads.** It raises a hoot down the same function, with
the same click, and reports which notifier raised it, so the person sees the notification
exactly when hoots work. It never asks herdr: herdr's popup setting has no say in a hoot, and
reading `[ui.toast]` out of config.toml was built and thrown away, since a hand-rolled parser
read herdr's stock `# delivery = "off"` comment as the setting. A warning, never a failure
(ADR-0038): `osascript` raising it means no click and no staying power, and the fix is
`brew install terminal-notifier`; no notifier at all is a silent machine. With
`terminal-notifier` it says to set Alerts in System Settings, and when nothing appears points
at the desktop's own settings or a missing notification server.

## Consequences

- A person who turns herdr's popups on gets herdr's toast for every mouse as well as
  Whiska's hoots; Whiska does not read the setting and cannot tell.
- The pointer line surfaces on the notification centre, lock screen and screen share
  included; the person's "show previews" setting is the lever. A hoot that said only "a
  question arrived" would cost the thing it is for, acting without opening anything.
- A machine with no notifier, a server or a container, raises nothing, and the doctor says
  so in words.
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
- **herdr first, the desktop when herdr refuses.** The rule until 2026-10-15: herdr's one
  switch cannot be on for Whiska without being on for every mouse, and off it answers
  `shown: true` and draws nothing, so the fallback never fired.
- **herdr's toasts on, filtered by `delay_seconds = 3600`.** Delays a mouse's toast an hour
  rather than stopping it.
- **Hold hoots a minute and group them per house.** Asked for and declined by the person:
  each arrives at once and stays.
- **`terminal-notifier` first on macOS, when installed.** Built, dropped on 2026-10-11 as a
  Homebrew add-on doing what `osascript` already did, and built again on 2026-10-15: its
  click, which jumps to the main session, is what `osascript` cannot do.

Folded in on 2026-10-08: 0071 (its text is in git history).

Changed on 2026-10-14: a finished report hoots as it is collected, never on delivery, and
a finished branch with work to land is reminded every two hours.

Changed on 2026-10-14, again: the report ending a review round that pushed nothing does
not hoot.

Changed on 2026-10-15: a finished report's line is typed again once nothing waits
(ADR-0008); its hoot stays at collection, and the line raises none.

Changed on 2026-10-15, again: hoots no longer go through herdr, which cannot filter its
toasts per pane and answers `shown: true` with popups off; `terminal-notifier` raises them
with a click that jumps to the main session; the owl logs each; the doctor probes the desktop
alone.
