# No test may touch the person's own `~/.whiska` (ADR-0039), their
# `~/Library/LaunchAgents` or `~/.config/systemd/user` (ADR-0040), so both
# homes go to one temp folder per run, set before a single test starts. A test
# that pins a home of its own still overrides these; `Whiska.Test.HomeGuard`
# checks after every test that whatever it put back is still safe.
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

# A suite run by a `claude` that itself runs under another `claude` — a
# `claude -p` running the checks — would read every hook test as nested
# (ADR-0084). A test that wants the check
# passes its own `CLAUDE_PID`.
System.delete_env("CLAUDE_PID")

# The person's own diff link pattern would turn every diff file test into one
# about their viewer. A test that wants a pattern sets its own.
System.delete_env("WHISKA_DIFF_LINK")

# Whiska's own git calls inherit this environment, so a test cannot pass on the
# person's git config, hooks or global ignore file and fail on any other
# machine. git reads `~/.config/git/ignore` with no config naming it, so the
# ignore file is pointed at nothing too; with no config there is no identity,
# so every commit gets one.
for {name, value} <- [
      {"GIT_CONFIG_GLOBAL", "/dev/null"},
      {"GIT_CONFIG_SYSTEM", "/dev/null"},
      {"GIT_CONFIG_COUNT", "1"},
      {"GIT_CONFIG_KEY_0", "core.excludesFile"},
      {"GIT_CONFIG_VALUE_0", "/dev/null"},
      {"GIT_AUTHOR_NAME", "Test"},
      {"GIT_AUTHOR_EMAIL", "test@example.com"},
      {"GIT_COMMITTER_NAME", "Test"},
      {"GIT_COMMITTER_EMAIL", "test@example.com"}
    ],
    do: System.put_env(name, value)

Mox.defmock(Whiska.Herdr.Mock, for: Whiska.Herdr)
Mox.defmock(Whiska.Desktop.Mock, for: Whiska.Desktop)
# `live_desktop` draws a real notification; run it with `--include live_desktop`.
# `e2e` drives the real binary through a private herdr for about forty seconds;
# `mix test.e2e` runs it. `macos` needs a program only macOS ships, such as
# `plutil`, and runs only there; `systemd` needs `systemd-analyze`, and
# `notify_send` needs `notify-send`.
ExUnit.start(
  formatters: [ExUnit.CLIFormatter, Whiska.Test.HomeGuard],
  exclude:
    [:live_desktop, :e2e] ++
      if(:os.type() == {:unix, :darwin}, do: [], else: [:macos]) ++
      if(System.find_executable("systemd-analyze"), do: [], else: [:systemd]) ++
      if(System.find_executable("notify-send"), do: [], else: [:notify_send])
)
