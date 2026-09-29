# No test may touch the person's own `~/.whiska` (ADR-0039) or their
# `~/Library/LaunchAgents` (ADR-0040), so both homes go to one temp folder per
# run, set before a single test starts. A test that pins a home of its own
# still overrides these; `Whiska.Test.HomeGuard` checks after every test that
# whatever it put back is still safe.
#
# `WHISKA_HOME` is set too because it is the fallback `Whiska.OpenHouses.home/0`
# reaches when the `:home` setting is missing, and a missing setting must still
# land in the temp folder.
test_home = Path.join(System.tmp_dir!(), "whiska-test-home-#{System.system_time(:nanosecond)}")
whiska_home = Path.join(test_home, ".whiska")

Application.put_env(:whiska, :home, whiska_home)
Application.put_env(:whiska, :user_home, test_home)
System.put_env("WHISKA_HOME", whiska_home)
File.mkdir_p!(whiska_home)

ExUnit.after_suite(fn _ -> File.rm_rf!(test_home) end)

Mox.defmock(Whiska.Herdr.Mock, for: Whiska.Herdr)
ExUnit.start(formatters: [ExUnit.CLIFormatter, Whiska.Test.HomeGuard])
