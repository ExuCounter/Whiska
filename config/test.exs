import Config

config :whiska, :herdr, Whiska.Herdr.Mock

# The whiska home (ADR-0039) and the user home the owl's plist hangs off
# (ADR-0040) are set in `test/test_helper.exs`: they need a fresh temp folder
# per run, outside the person's own home, and the checkout `_build` sits in is
# usually inside it.

# The service manager is pinned, so the suite reads the same on macOS and
# Linux; the systemd tests ask for `Whiska.SystemdUnit` themselves. Both
# runners refuse, so no test can reach the real launchctl or systemctl.
config :whiska, :service_manager, Whiska.LaunchAgent
config :whiska, :launchctl, &Whiska.Test.NoLaunchctl.run/1
config :whiska, :systemd, &Whiska.Test.NoSystemctl.run/1

# No notifier, so a hoot herdr refuses never reaches the real desktop
# (ADR-0062).
config :whiska, :desktop, Whiska.Test.NoDesktop
