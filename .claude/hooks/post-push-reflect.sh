#!/usr/bin/env bash
# PostToolUse hook (matcher: Bash). After a successful `git push`, ask the session to
# run two reflection skills before moving on:
#   - lesson-learned  — what did this change actually teach us?
#   - domain-modeling — did the vocabulary or a decision shift? CONTEXT.md / docs/adr/
#
# A hook cannot invoke a skill. It injects context asking the session to; complying is
# the model's call. Fires at most once per pushed commit (keyed on HEAD), so repeated
# pushes of the same commits stay quiet.

set -eu

payload="$(cat)"

command -v jq >/dev/null 2>&1 || exit 0
command -v git >/dev/null 2>&1 || exit 0

cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty')"
[ -n "$cmd" ] || exit 0

# Push-shaped. Err broad — a false nudge costs nothing, a missed one loses the habit —
# then subtract the obvious false positives: dry runs, ref deletions, and read-only
# subcommands that merely mention the word (`git log --grep push`).
printf '%s' "$cmd" | grep -Eq '(^|[;&|[:space:]])git([[:space:]]+[^;&|]*)?[[:space:]]+push([[:space:]]|$)' || exit 0
printf '%s' "$cmd" | grep -Eq '(--dry-run|--delete)' && exit 0
printf '%s' "$cmd" | grep -Eq '(^|[;&|[:space:]])git[[:space:]]+(log|show|grep|config|help|diff)([[:space:]]|$)' && exit 0

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
git_dir="$(git rev-parse --git-common-dir 2>/dev/null)" || exit 0
head_sha="$(git rev-parse HEAD 2>/dev/null)" || exit 0

# Confirm the push actually landed rather than trusting that the command ran: the
# upstream ref has to point at HEAD now. A failed push leaves it behind, so we stay
# quiet AND leave the state file alone, so the successful retry still nudges.
upstream_sha="$(git rev-parse '@{u}' 2>/dev/null)" || exit 0
[ "$upstream_sha" = "$head_sha" ] || exit 0

state="$git_dir/whiska-reflect-head"
[ -f "$state" ] && [ "$(cat "$state")" = "$head_sha" ] && exit 0
printf '%s' "$head_sha" > "$state"

jq -n '{
  hookSpecificOutput: {
    hookEventName: "PostToolUse",
    additionalContext: (
      "A push just landed. Before starting anything new, run both reflection skills on what was pushed — this is a standing rule in this repo'"'"'s CLAUDE.md, not a suggestion from the diff:\n\n" +
      "1. `lesson-learned` — on the commits just pushed. Keep what it surfaces; discard nothing silently.\n" +
      "2. `domain-modeling` — check whether this change introduced, renamed, or sharpened any domain term (update CONTEXT.md) or settled a decision that meets the ADR bar (add to docs/adr/, update its README index).\n\n" +
      "If either turns up nothing worth writing down, say so in one line and move on. Do not skip them silently."
    )
  }
}'
