# The owl is kept running by the platform's service manager: launchd on macOS, systemd on Linux

Each platform's own user service manager starts the owl at login and restarts it after a
crash. `Whiska.ServiceManager` is the behaviour; `Whiska.LaunchAgent` and
`Whiska.SystemdUnit` answer to it, picked by `:os.type()`. ADR-0001 chose one owl per
machine partly because that is the shape a service manager supervises cleanly, and before
this the owl ran in the foreground of whichever pane started it, died once for a reason
nobody found, and nobody noticed until a mouse asked why its question was not delivered.

## Decision

**macOS: a user LaunchAgent, `com.whiska.owl`**, at `~/Library/LaunchAgents/`, loaded into
the `gui` domain, `RunAtLoad` true. **Linux: a user unit, `whiska-owl.service`**, at
`~/.config/systemd/user/`, the plist translated rather than redesigned: `Restart=on-failure`,
`RestartSec=10` (launchd's own throttle, and it keeps a crash loop under systemd's start
limit so the unit keeps retrying). Both append to `~/.whiska/owl.log`, not the journal, so
the doctor and the person look in one place on both platforms. Not `brew services`, a
wrapper around the same plist; not socket activation (ADR-0036).

**Both run a wrapper, `~/.whiska/owl.sh`, not the escript.** Neither manager's PATH can
find `escript`, so `#!/usr/bin/env escript` never resolves. The wrapper is generated from
the same shell fragments as the hook shim (ADR-0035) and resolves the binary and the
runtime at every launch, so an Erlang upgrade needs no reinstall. The unit runs it through
its own `#!/usr/bin/env bash`: NixOS and Guix have no `/bin/bash`. `WHISKA_BIN`,
`WHISKA_ESCRIPT`, `WHISKA_HOME` and `HERDR_SOCKET_PATH` are copied from the installing
shell when set; nothing else is passed. With `HERDR_SOCKET_PATH` unset the owl uses herdr's
fixed default socket, since a supervised job inherits no pane's environment.

**A crash restarts, a clean exit does not.** `KeepAlive` is `SuccessfulExit = false`, not
`true`, which is what lets `whiska owl stop` be a clean exit 0 that stays stopped with the
job still loaded. Under the manager the owl starts with no arguments, opens what the
open-houses record lists (ADR-0039), and with nothing recorded idles rather than exits: an
exit would be a crash and a restart loop.

**The verbs mean the same on both:**

| Command | launchd | systemd | The owl |
|---|---|---|---|
| `whiska owl install` | writes and loads the job | writes the unit, `daemon-reload`, `enable --now` | starts, reopening the recorded houses |
| `whiska owl stop` | job stays loaded | `stop`; unit stays enabled | exits 0; back on `start` or the next login |
| `whiska owl start` | `kickstart` | `start` | starts now |
| `whiska owl uninstall` | boots the job out, removes the files | `disable --now`, removes the files | stops; nothing restarts it |
| `whiska owl` | refused if the supervised owl runs | same | foreground |
| `whiska stop` | — | — | **not this**: one house (ADR-0003), unbuilt until the per-repo socket (ADR-0024) |

`whiska stop` keeps its per-house meaning and says so, pointing at `whiska owl stop`,
rather than taking the per-house verb's name for the owl.

**Never two owls.** Two owls collect the same doorsteps and each entry becomes a question
twice. `whiska owl install` refuses while any owl is in the process table, naming the
handover; the foreground `whiska owl` refuses while the supervised one runs. The refusal
knows which owl it is looking at: `Whiska.CLI.start_owl/2` compares the pid the manager
reports with its own, because the wrapper `exec`s and the pid carries through to the BEAM.
The first real install crash-looped on exactly this: the supervised owl refused itself as
"already running", exited 1, and was restarted every time. A pid comparison answers "am I
that process?"; an environment marker would be inherited by every child and let a
descendant become the second owl.

**Lingering is said, never set.** systemd stops a user's services when their last session
ends unless `loginctl enable-linger` is on; over SSH that means closing the last terminal
stops the owl. It is a machine setting that outlives Whiska, so `install` prints the
command and the doctor's `logout` line warns while it is off. launchd has no such switch.

**No systemd for this user is a refusal with a way out.** Containers and WSL without
systemd: `install` exits 1 and says to run `whiska owl` in a pane; the doctor says the same.
Every manager call goes through a runner that answers a missing program as a failed call,
never a raise, so the foreground owl and the doctor start anywhere.

**The doctor** has a `launch agent` or `systemd unit` line: not installed, written but not
loaded, loaded but not running, crash-looping (loaded, no pid, non-zero last exit code, the
line that names the bug above), two owls. Warnings with their fix, never failures
(ADR-0038).

## Consequences

- The handover from a foreground owl is by hand: stop it, then install. The record makes
  it painless.
- The log is not rotated.
- `Whiska.Owl.pids/0` excludes the calling process; `pgrep -f "whiska owl"` matches
  `whiska owl install` itself.
- The test config pins the manager to launchd and both runners refuse the real program;
  the systemd tests ask for `Whiska.SystemdUnit` themselves and verify the unit with
  `systemd-analyze verify` where it exists. Verified by hand in a Debian container.
- One macOS-only call remains, in code not yet written: ADR-0024's peer check names
  `LOCAL_PEERPID`; Linux's is `SO_PEERCRED`.

## Alternatives

- **Resolve the runtime at install time and bake it in.** An Erlang upgrade breaks the
  job silently, and under restart-on-crash silently means a restart loop.
- **`KeepAlive = true`.** The only stop would be uninstalling.
- **No supervisor on Linux.** Reopens the failure this record was written for.
- **Whiska's own restart loop.** Rebuilds what both platforms ship and still needs
  something to start it at login.
- **Turn lingering on during install.** Changes a machine setting the person did not ask
  for, and it outlives uninstall.
- **Journal logging under systemd.** Two places to look.

Folded in on 2026-10-08: 0077 (its text is in git history).
