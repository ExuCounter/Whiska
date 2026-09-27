# The owl is supervised by a user LaunchAgent, and `whiska owl stop` stops the whole owl

ADR-0001 chose one owl per machine partly *because* that is the shape `launchd` supervises
cleanly, and CONTEXT.md has called the owl "supervised by `launchd`" since the design was
written. It was not: the owl ran in the foreground of whichever pane `whiska owl <repo>…`
was typed in, and the day this was built it had died once for a reason nobody found, and
nobody noticed until a mouse asked why its question was not being delivered. This ADR
records how the supervision is wired, and what the stop verbs mean under it.

## Decision

**A user LaunchAgent, `com.whiska.owl`, is the one supervisor.** `whiska owl install`
writes it to `~/Library/LaunchAgents/` and loads it into the user's `gui` domain;
`RunAtLoad` starts the owl at login and `KeepAlive` restarts it if it crashes. Not
`brew services`, which the spec mentioned: that is a wrapper around the same plist, and
Whiska is not a formula yet. Not socket activation, which ADR-0036 already rejected.

**The plist runs a wrapper, not the escript.** launchd starts a job with
`PATH=/usr/bin:/bin:/usr/sbin:/sbin`, so an escript's `#!/usr/bin/env escript` never
resolves. The alternative was to resolve the runtime's absolute path once, at install
time, and bake it in. Rejected for the reason ADR-0035 gives for the hook shim: an Erlang
upgrade would break the job silently, and under `KeepAlive` silently means a restart loop
in the log. So the plist runs `~/.whiska/owl.sh`, generated from the *same* shell
fragments the hook shim and the statusline script are built from (`Whiska.Install`), and
that wrapper resolves the binary and the runtime at every launch. Three scripts, one
source, no drift. `WHISKA_BIN`, `WHISKA_ESCRIPT`, `WHISKA_HOME` and `HERDR_SOCKET_PATH`
are copied from the installing shell into the plist's environment when set; launchd
passes nothing else on.

**`KeepAlive` is `SuccessfulExit = false`**, not `true`. launchd restarts a crash and
leaves a clean exit alone. That is what makes the stop verb possible without
uninstalling: `whiska owl stop` sends `TERM`, the BEAM turns it into a clean exit 0,
and the job stays loaded and comes back at the next login or on `whiska owl start`.
With `KeepAlive = true` the only way to stop the owl would be to boot the job out, which
is uninstalling by another name.

**Under launchd the owl starts with no arguments.** It opens whatever the open-houses
record (ADR-0039) lists; started from the home directory with nothing recorded it opens
no house, says so, and idles until `whiska owl <repo>` records one. Idling rather than
exiting matters here: an exit would be a crash to launchd and a restart loop.

**`HERDR_SOCKET_PATH` falls back in code.** A launchd job inherits no pane's environment.
herdr 0.8.2 puts its socket at a fixed `~/.config/herdr/herdr.sock` and recreates it there
on every restart, so the owl uses that when the variable is unset, and the plist's copy
wins when it was set at install — a named herdr session lives elsewhere.

**Two owls is the one state install must never produce.** Two owls collect the same
doorsteps, and each entry would become a question twice. So `whiska owl install` refuses
while any owl is in the process table — a foreground one, with the handover spelled out
(Ctrl-C it, install again), or launchd's own, pointing at `whiska owl stop` first. And
the foreground `whiska owl` refuses while launchd's owl is running. The doctor names both
when it finds them.

## What the verbs mean

| Command | launchd | The owl |
|---|---|---|
| `whiska owl install` | writes and loads the job | starts, reopening the recorded houses |
| `whiska owl stop` | job stays loaded | exits 0; back at login or on `start` |
| `whiska owl start` | `kickstart` | starts now |
| `whiska owl uninstall` | boots the job out, removes the files | stops; nothing restarts it |
| `whiska owl` | untouched; refused if launchd's owl runs | foreground, as before |
| `whiska stop` | — | **not this.** One house, per ADR-0003; needs the socket, not built |

`whiska stop` keeps ADR-0003's meaning exactly — shut *this repo's* house, the owl keeps
running for every other — and stays unbuilt until the owl can be told about one house,
which is the per-repo or global socket (ADR-0024, ADR-0025). Until then it prints that,
and points at `whiska owl stop`. The temptation was to let `whiska stop` mean the owl
because that is what can be built today; it was refused because it would take the
per-house verb's name for a different thing, and ADR-0003 would have to be rewritten to
cover the wrong operation.

## The doctor

One new line, `launch agent`, right after `owl` (ADR-0038: checks and probes, never
repairs). Not installed is a warning — the owl is unsupervised and dies with its pane —
and so is written-but-not-loaded, loaded-but-not-running (with the log's path), and two
owls. Each carries its fix: `whiska owl install`, `whiska owl start`, or Ctrl-C the
foreground one.

## Consequences

- The handover from a foreground owl is by hand and in that order: stop the foreground
  owl, then `whiska owl install`. The record (ADR-0039) is what makes it painless — the
  supervised owl reopens the same houses.
- The owl's stderr, which ADR-0038 called "the one person who needs to know is the one
  it cannot reach", now lands in `~/.whiska/owl.log`. Nothing rotates it yet.
- `Whiska.Owl.pids/0` now excludes the calling process: `pgrep -f "whiska owl"` matches
  `whiska owl install` itself.
- The plist, the wrapper and the install and uninstall writes are unit-tested against a
  temporary home; the test config points the user home and the launchctl runner away from
  the real machine, so no test can load a job. `launchctl` itself, and the handover, are
  verified by hand.
- The `launchd` node of the deployment diagram, and the "launchd service" container, move
  from designed to built.
