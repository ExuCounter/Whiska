# The owl is kept running by the platform's own service manager: launchd on macOS, systemd on Linux

Amends ADR-0040. Its decision said "a user LaunchAgent, `com.whiska.owl`, is the one
supervisor", which only means anything on macOS. On Linux there is no `launchctl`. Worse,
`whiska owl` and `whiska doctor` asked `launchctl` before doing anything else, and a
missing program raises, so on Linux the owl did not start even in the foreground. Other
people now run Whiska (decided 2026-10-04), and herdr runs on Linux, so Linux is a real
platform rather than a hypothetical one.

## Decision

**Each platform's own user service manager keeps the owl running.** On macOS that is
launchd, through ADR-0040's LaunchAgent, unchanged. On Linux it is systemd, through a user
unit, `~/.config/systemd/user/whiska-owl.service`. `Whiska.ServiceManager` is the
behaviour both answer to. `Whiska.LaunchAgent` and `Whiska.SystemdUnit` are its two
implementations. `:os.type()` picks one: launchd on Darwin, systemd everywhere else.

**The verbs mean the same on both.** ADR-0040's table holds with systemd in launchd's
column:

| Command | systemd | The owl |
|---|---|---|
| `whiska owl install` | writes the unit, `daemon-reload`, `enable --now` | starts, reopening the recorded houses |
| `whiska owl stop` | `stop`; the unit stays enabled | exits 0; back on `start`, or when systemd next starts the user's session |
| `whiska owl start` | `start` | starts now |
| `whiska owl uninstall` | `disable --now`, removes the files, `daemon-reload` | stops; nothing restarts it |
| `whiska owl` | untouched; refused if systemd's owl runs | foreground, as before |

**The unit is the plist translated, not redesigned.** It runs the same wrapper,
`~/.whiska/owl.sh`, for ADR-0040's reason: systemd's user manager hands a service a bare
`PATH` too. The wrapper moved to `Whiska.ServiceManager` so both share one copy. The unit
runs it directly, through its own `#!/usr/bin/env bash`, rather than through `/bin/bash`
as the plist does: NixOS and Guix run systemd and have no `/bin/bash`.
`Restart=on-failure` is `KeepAlive = {SuccessfulExit = false}`, so a crash restarts and a
clean exit does not. `RestartSec=10` is launchd's own throttle. It also keeps a crash loop
under systemd's start limit of five starts in ten seconds, so the unit keeps retrying the
way launchd does instead of giving up. Output is appended to `~/.whiska/owl.log`, not the
journal, so the doctor and the person look in one place on both platforms. The same four
variables pass through from the installing shell. "Loaded" is `UnitFileState=enabled`.
The pid and last exit code come from `systemctl --user show`, which, unlike
`launchctl print`, is a documented key=value format.

**A stopped owl comes back when systemd next starts the user's session**, or on
`whiska owl start`. With lingering on, that session outlives every login, so a stopped owl
stays stopped until a reboot or `start`. Without it, it comes back at the first login after
every session has ended. The messages say so rather than promise "the next login".

**Lingering is said, never set.** systemd stops a user's services when their last
session ends, unless lingering is on (`loginctl enable-linger`). On a desktop that matches
launchd: the owl lives as long as the login. Over SSH it means closing the last terminal
stops the owl. Lingering is a machine setting that outlives Whiska, so `whiska owl install`
does not turn it on. It prints the command when lingering is off, and the doctor's
`logout` line warns while it stays off. launchd has no such switch for a user agent, so
there is no line on macOS.

**No systemd for this user is a refusal with a way out, not a crash.** Most containers,
and WSL without systemd, have no user manager. There, `whiska owl install` exits 1 and
says to run `whiska owl` in a pane. The doctor's `systemd unit` line says the same, with
that as its only fix, and there is no `logout` line, since neither `whiska owl install`
nor `loginctl` would work there. Every call a manager makes goes through a runner, and
a runner whose program is missing answers as a failed call, never a raise. So the
foreground owl and the doctor start anywhere.

## Alternatives

- **No supervisor on Linux.** Fix the crash and run the owl in a pane. Cheapest, but it
  reopens the failure ADR-0040 was written for: the owl dies with its pane, and nobody
  notices until a question goes undelivered.
- **Whiska's own restart loop**, a wrapper that respawns the owl. It runs anywhere, but it
  rebuilds what both platforms already ship, and it still needs something to start it at
  login.
- **Turn lingering on during install.** It makes the owl survive logout, but it changes a
  machine setting the person did not ask to change, and it outlives `whiska owl uninstall`.
- **Journal logging under systemd.** It is more idiomatic, but the doctor and the docs
  would then point at a different place on each platform.

## Consequences

- On macOS nothing changes. The plist, its path and its label are as ADR-0040 left them.
  The doctor's line is still called `launch agent`.
- On Linux the doctor's line is called `systemd unit` and reads the same states:
  not installed, written but not loaded, loaded and running, crash-looping, and two owls.
  A `logout` line follows it.
- The test config pins the manager to launchd, so the suite reads the same on both
  platforms. The systemd tests ask for `Whiska.SystemdUnit` themselves. Both runners
  refuse to reach the real program. `test/whiska/systemd_unit_test.exs` checks the unit
  with `systemd-analyze verify` where that program exists.
- One macOS-only call is left, and it is in code not yet written: ADR-0024's peer check
  for the designed sockets names `LOCAL_PEERPID`. Linux's equivalent is `SO_PEERCRED`,
  and the choice belongs to whoever builds the sockets.
- Verified by hand on 2026-10-05 in a Debian container running systemd as PID 1: install,
  stop, start and uninstall drive a real user manager, the owl runs with systemd's pid as
  its own, and a crash is restarted.
