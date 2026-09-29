import Config

config :whiska, :herdr, Whiska.Herdr.Mock

# The whiska home (ADR-0039) and the user home the owl's plist hangs off
# (ADR-0040) are set in `test/test_helper.exs`: they need a fresh temp folder
# per run, outside the person's own home, and the checkout `_build` sits in is
# usually inside it.

# launchctl is a runner that refuses, so no test can reach the real one.
config :whiska, :launchctl, &Whiska.Test.NoLaunchctl.run/1
