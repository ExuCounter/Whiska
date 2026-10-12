#!/bin/bash
# Render the mouse's rules out of this checkout into cond/, as the SessionStart hook
# prints them (cond/session-start.json) and as a block for CLAUDE.md (cond/rules-block.md).
# Run from anywhere inside the repo; needs a compiled Whiska (mix compile).
set -e
here="$(cd "$(dirname "$0")" && pwd)"
cd "$(git rev-parse --show-toplevel)"
EXP="$here" mix run -e '
rules = Whiska.Rules.render(:mouse)
cond = Path.join(System.get_env("EXP"), "cond")
File.write!(Path.join(cond, "rules.md"), rules)
File.write!(
  Path.join(cond, "session-start.json"),
  JSON.encode!(%{"hookSpecificOutput" => %{"hookEventName" => "SessionStart", "additionalContext" => rules}})
)
'
cd "$here/cond"
{ printf '\n<!-- whiska:start -->\n'; cat rules.md; printf '\n<!-- whiska:end -->\n'; } > rules-block.md
ls -l "$here/cond"
