# The owl's line is drawn once on herdr's tab bar, machine-wide

One line says what is true of the whole machine, and herdr draws it: a `tab_bar_right`
command entry in the person's own herdr config runs `~/.whiska/herdr-status.sh` every five
seconds, with a two-second timeout, and shows its last line. The script asks the owl's
read-only socket (ADR-0033) with `nc -U`, one `line` request, and prints the answer. It
starts no Erlang and looks for no binary. Nothing of it runs in any Claude Code session.

## What the line says

```
🦉 watching
🦉 watching · 🐱 new-linkedin-plugin
🦉 watching · 🐱 2 whiskas · ⌃a space
🦉 watching · away
🦉 owl down
```

- **The owl's state, always.** An empty line is exactly what a broken Whiska draws, and
  herdr clears an entry on empty output, so a quiet machine and a dead owl would look the
  same. This is the one segment that is never absent. The owl that answers is `watching`
  unless doorstep entries have waited past the backstop: up and not collecting is down.
- **Detail for one thing, a count for many.** One whiska with something waiting is named by
  its repo; several are a count; nothing waiting adds no segment. It counts whiskas, not
  questions: the bar answers "how many places need me", and a place is a house's main
  session, where a jump lands (ADR-0043). Two questions in one repo are one place to go.
  Held questions are not counted (ADR-0079).
- **`away`** while the person has set it (ADR-0079).
- **The jump key**, when something not held is waiting, and only if the person passed it as
  the script's one argument: `command = "~/.whiska/herdr-status.sh '⌃a space'"`. The binding
  lives in the person's herdr config, which Whiska never reads, so the script is told.
- **Nothing answering reads `🦉 owl down`, with no count.** No socket, a socket file a
  crashed owl left, an owl hung past one second: all one line. `whiska waiting` still lists
  everything with the owl down. `🦉 nc missing` and `🦉 nc cannot reach the owl` (GNU
  netcat has no Unix sockets) say which tool is the problem, so the line never goes blank.
- **No mice segment.** herdr's sidebar shows each mouse's line two inches away (ADR-0082).

## Why here

Delivery cannot report its own outage: when the owl is not answering, the channel that
would carry the message is the channel that is broken. The tab bar is drawn by herdr's
server on its own timer, so it is the one signal that still works when the owl is down.

One pull serves the whole machine. Drawing the same line in every Claude Code session's
statusline cost one script run per session per interval: 0.81 core-seconds of CPU per run,
about 5% of a core per idle session, about 22% with four open, for one fact repeated four
times on one screen. The cost scaled with the sessions and the information did not.

The line is machine-wide because herdr's config is one file and the tab bar is one surface
for the whole window. A line whose meaning changed as the person switched workspaces would
be harder to read, not easier, and a machine-wide line has no "elsewhere" to name.

## The person owns the registration

`whiska owl install` writes the script into the whiska home and prints the entry to paste.
Whiska never edits `~/.config/herdr/config.toml`: it is machine-global and hand-edited, and
a per-repo `whiska init` writing into it is the boundary ADR-0056 draws. `whiska doctor`
reads the config, accepts the script's path written out or under a tilde and with an
argument after it, and warns with the snippet when the entry is missing. A warning, never a
failure (ADR-0038): questions are collected, recorded and delivered whether or not the line
is drawn. The sidebar's colour rows are the person's in the same way (ADR-0082).

## Consequences

- Outside herdr there is no line: a bare `claude` in a terminal, or a remote attach from a
  machine without the config, shows nothing. Accepted; mice are herdr panes (ADR-0020).
- herdr's plugin system cannot add a status segment (checked against 0.8.2 and 0.9.2),
  so a plugin was never an option.
- `whiska statusline` prints the same line without the owl, reading every recorded house
  (ADR-0039), and takes no repo.

## Considered options

- **Keep the line in every Claude Code session's statusline on a timer.** The arithmetic
  above; and the per-session timer ran a committed script from the moment a repo was
  opened, widening the trust a cloned `.claude/` asks for from "using a tool" to "opening
  this". Gone with the statusline (ADR-0082).
- **Keep both lines for a while.** Two lines saying the same thing is what this decision
  removes; the fallback was maintenance for nobody.
- **A per-house line following the focused workspace.** herdr hands the entry the active
  pane's directory, so it could. Rejected: one surface, one meaning.
- **Count questions, not whiskas.** The person read `5 waiting` as five repos and asked.
- **Keep `🐭 N mice` on the bar.** The sidebar already shows each pane's state, one row
  each, which is more than a count.
- **Report the waiting count when the owl is down**, by reading every house directly.
  Needs Erlang in the script; the person chose the plain line.

Folded in on 2026-10-08: 0027 (its text is in git history).
