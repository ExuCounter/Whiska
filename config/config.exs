import Config

# The hook runs on every tool call and Claude Code surfaces its stderr to the
# user, so the CLI must be quiet by default: a stray Logger line from a
# dependency becomes noise on every single tool call. Whiska's own diagnostics
# go out through explicit `IO.puts(:stderr, ...)` calls, which are unaffected by
# this and stay visible.
config :logger, level: :none

config :whiska, Whiska.Repo,
  priv: "priv/repo",
  # Migrations are handed to Ecto.Migrator as compiled modules; see
  # Whiska.Migrations.V001CreateMiceAndQuestions for why.
  log: false
