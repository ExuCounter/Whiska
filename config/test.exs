import Config

config :whiska, :herdr, Whiska.Herdr.Mock

# The open-houses record lives under ~/.whiska on a real machine (ADR-0039).
# Tests must never touch the person's own, so the whole `.whiska` folder is
# pointed into the build directory here; tests that care pin a path of their own.
config :whiska, :home, Path.expand("../_build/test/whiska-home", __DIR__)

# The owl's LaunchAgent (ADR-0040) is likewise kept off the real machine: the
# plist goes under a fake user home, and launchctl is a runner that refuses.
config :whiska, :user_home, Path.expand("../_build/test/user-home", __DIR__)
config :whiska, :launchctl, &Whiska.Test.NoLaunchctl.run/1
