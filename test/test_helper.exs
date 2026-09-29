# No test may touch the person's own `~/.whiska` (ADR-0039) or their
# `~/Library/LaunchAgents` (ADR-0040). Running `mix test` once emptied the real
# open-houses record, and the owl then opened nothing until it was rewritten by
# hand, so both homes are pointed at one temp folder per run, before a single
# test starts. A test that forgets to set its own is isolated by this; a test
# that sets its own still overrides it; and `Whiska.Test.HomeGuard` checks after
# every test that whatever it put back is still safe.
#
# `WHISKA_HOME` is set as well because that is the fallback
# `Whiska.OpenHouses.home/0` reaches when the `:home` setting is missing — the
# exact hole a test that deletes the setting used to fall through.
test_home = Path.join(System.tmp_dir!(), "whiska-test-home-#{System.system_time(:nanosecond)}")
whiska_home = Path.join(test_home, ".whiska")

Application.put_env(:whiska, :home, whiska_home)
Application.put_env(:whiska, :user_home, test_home)
System.put_env("WHISKA_HOME", whiska_home)
File.mkdir_p!(whiska_home)

ExUnit.after_suite(fn _ -> File.rm_rf!(test_home) end)

Mox.defmock(Whiska.Herdr.Mock, for: Whiska.Herdr)
ExUnit.start(formatters: [ExUnit.CLIFormatter, Whiska.Test.HomeGuard])
