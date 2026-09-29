import Config

config :whiska, :herdr, Whiska.Herdr.Mock

# The whiska home (ADR-0039) and the user home the owl's plist hangs off
# (ADR-0040) are set in `test/test_helper.exs`, not here: they go to one temp
# folder per run, well outside the person's own home, and `_build` is not —
# the checkout usually sits under the home directory itself.

# launchctl is a runner that refuses, so no test can reach the real one.
config :whiska, :launchctl, &Whiska.Test.NoLaunchctl.run/1
