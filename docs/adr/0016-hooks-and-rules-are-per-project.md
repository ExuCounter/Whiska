# Hooks and rules are per-project, not global

`whiska init` writes the repo's own `.claude/settings.json`, checked into git, so anyone
who clones the repo and has Whiska installed gets the same rules automatically. Global
hooks were the alternative and were rejected: global means zero setup per project, but the
rules would not travel with a shared repo. Per-project keeps the repo the source of truth
for its own rules.

## Consequences

Turning Whiska on is an explicit per-project action, and upgrading Whiska itself
(`brew upgrade`) never touches a project automatically — `whiska update` is opt-in per
repo. It rewrites only the marked `<!-- whiska:start -->` / `<!-- whiska:end -->` block in
that project's `CLAUDE.md` and the installed skills, leaving everything else in the file
alone.
