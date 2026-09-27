import Config

config :whiska, :herdr, Whiska.Herdr.Mock

# The open-houses record lives under ~/.whiska on a real machine (ADR-0039).
# Tests must never touch the person's own, so the whole `.whiska` folder is
# pointed into the build directory here; tests that care pin a path of their own.
config :whiska, :home, Path.expand("../_build/test/whiska-home", __DIR__)
