# The owl's line is drawn once on herdr's tab bar, not in every Claude session

**Supersedes [ADR-0044](0044-the-statusline-redraws-on-a-timer-not-a-typed-nudge.md)**,
which kept the line in each Claude Code session's statusline and paid a
`refreshInterval: 15` timer, per session, to hold it current.

ADR-0044 solved the right problem the only way Claude Code allows. Its own
arithmetic is the argument against it: one run of the statusline script costs
about 0.44 s of wall clock, nearly all escript startup, so a 15 s timer is a ~3%
duty cycle *per idle session* — about 12% of a core with four sessions open, for
one line repeated four times on one screen. The cost scales with the number of
sessions; the information does not. Four copies of "the owl is watching" is three
copies too many.

herdr has a surface that is the right shape. `ui.tab_bar_right` is an ordered
status area at the right edge of the desktop tab row, entries of type `zoom`,
`hostname`, `datetime`, `text` and `command`. A `command` entry runs on the herdr
*server* every `interval_seconds`, with a `timeout_seconds`, never overlapping a
previous run and never blocking rendering. herdr takes the last line of
successful output, strips terminal control sequences, and clears the entry on
failure, empty output or timeout.

That makes it a pull, like `refreshInterval`, and the owl still cannot push. But
it is **one** pull for the whole herdr session rather than one per Claude Code
session, so five seconds there costs less than fifteen did here.

herdr's plugin system is not the surface. `herdr plugin` manifests carry `build`,
`startup`, `actions`, `events`, `panes` and `link_handlers`, and none of them can
add a status segment. Checked against herdr 0.8.2 and the 0.9.2 documentation.

## Decision

- **The line moves to herdr's tab bar, and leaves Claude Code.** `whiska init`
  writes no `statusLine` entry and no `.claude/hooks/whiska-statusline.sh`. An
  entry or script of ours left by an earlier init is removed on the next one;
  a script at that path Whiska did not write is somebody else's and stays.
- **The line is machine-wide.** herdr's config is one file for the whole machine
  and the tab bar is a whole-window surface, so a line whose meaning changed as
  the person switched workspaces would be the confusing option. `whiska
  statusline` is no longer repo-scoped; it reads every recorded house, exactly as
  `whiska waiting` does.
- **Two segments, and no more.** The owl, always, and what is waiting:

  ```
  🦉 watching
  🦉 watching · 🐱 feat-auth
  🦉 watching · 🐱 3 waiting
  🦉 owl down
  🦉 owl down · 🐱 4 waiting
  ```

  ADR-0027's one-or-many rule is unchanged: one thing waiting is named by its
  mouse's branch, several become a count, nothing waiting adds no segment.
- **The owl's state stays a segment of its own.** ADR-0027 rendered a dead owl as
  `🦉 owl down · 4 waiting`, one segment carrying both facts. Machine-wide, that
  count *is* the waiting segment's count, so the two are split: the owl says its
  state, the cat says what waits, in both states.
- **No mice segment.** herdr's own sidebar already shows every agent pane and its
  state, so `🐭 2 mice` on herdr's own tab bar is the same fact drawn twice.
- **No elsewhere segment.** It named the other repo with something waiting
  (ADR-0027). A machine-wide line has no elsewhere; that is what the whole line
  now is. The whiska headcount (`🐈 N whiskas`) goes with it — it existed to say
  how many screens the line was being drawn on.
- **5 seconds and a 2 second timeout.** One process per interval for the whole
  machine rather than one per idle session, so the tenfold cost reduction buys
  three times the freshness and still costs a fraction of ADR-0044. The timeout
  is well clear of the escript startup the script pays for. herdr accepts
  1–31,536,000 and 1–3,600 respectively.
- **The person owns the registration.** Whiska writes the script — `whiska owl
  install` puts `herdr-status.sh` in the whiska home, beside the owl's launchd
  wrapper and the open-houses record — and never edits `~/.config/herdr/config.toml`.
  That file is machine-global and hand-edited; a per-repo `whiska init` writing
  into it is exactly the boundary ADR-0016 draws. `whiska owl install` prints the
  entry to paste, and the person commits it with their dotfiles.
- **The doctor checks it and does not repair it** (ADR-0038). It reads herdr's
  config, looks for a `tab_bar_right` line naming the shipped script, and warns
  with the snippet to paste when there is none. Never a failure: nothing is lost
  when the line is missing — questions are still collected, recorded and
  delivered.
- **A Whiska the script cannot find says so.** herdr clears the entry on empty
  output, which is indistinguishable from nothing being configured — the exact
  blankness ADR-0027's second addendum exists to prevent. So the script prints
  `🦉 whiska missing` rather than nothing.

## Consequences

- **The line is gone outside herdr.** A `claude` run in a bare terminal, or a
  `herdr --remote` attach from a machine without the config, shows nothing. That
  is accepted: the person works in herdr, and mice are herdr panes by definition
  (ADR-0020).
- **Every repo initialised before today keeps a `statusLine` entry** pointing at a
  script that still works but is no longer written or maintained. The next
  `whiska init` in that repo removes both. Nothing breaks in the meantime — the
  old script calls `whiska statusline`, which now prints the machine-wide line, so
  the entry simply shows the new line in the old place.
- **ADR-0027's segments are cut down** rather than rewritten: the one-or-many rule
  and "the owl's state is always shown" both survive and are the reason the line
  looks the way it does. Its mice, whiskas and elsewhere segments are retired,
  and its addendum of 2026-09-29 about `refreshInterval` goes with ADR-0044.
- **`whiska statusline` no longer takes a repo.** It is the third command that
  does not, after `whiska waiting` and `whiska jump`, and for the same reason
  (ADR-0039: the record says which repos to look in).
- **`Whiska.Statusline` stops asking herdr for panes.** Mice, whiskas and
  elsewhere were the only readers of `pane.list` there, so the statusline no
  longer touches the herdr boundary at all — one fewer socket call every interval,
  and ADR-0025's addendum about what a refresh costs shrinks to the per-house
  SQLite reads `Whiska.Waiting` already does.
- **CONTEXT.md retires Nudge's last clause.** The entry explained that the
  elsewhere segment it existed to refresh was kept current by `refreshInterval`
  instead. Neither exists now.

## Considered options

**Keep both lines, Claude Code's and herdr's, for a while.** Recommended when this
was put to the person, and declined: two lines saying the same thing is what this
decision is about, and living with the duplicate would have meant maintaining the
`refreshInterval` check, the per-repo script and the elsewhere segment for the
sake of a fallback nobody wanted.

**A per-house line that follows the focused workspace.** herdr hands a `command`
entry `HERDR_ACTIVE_PANE_CWD`, so the script could resolve the house the person
is looking at and draw the old repo-scoped line. Rejected: the tab bar is one
surface for the whole window, and a line that silently changes meaning as the
person switches workspace is harder to read, not easier. Machine-wide also makes
the elsewhere segment redundant instead of relocating it.

**A herdr plugin.** There is no plugin surface for a status segment; the manifest
has no such key. Not an option, not a trade.

**Keep `🐭 N mice` on the tab bar.** Rejected: herdr's sidebar is two inches away
and already shows each agent pane's state, one row each, which is strictly more
than a count.
