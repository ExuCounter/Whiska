#!/usr/bin/env bash
# PostToolUse hook (matcher: Bash). After a successful `git push`, ask the session to
# run two reflection skills before moving on:
#   - lesson-learned  — what did this change actually teach us?
#   - domain-modeling — did the vocabulary or a decision shift? CONTEXT.md / docs/adr/
#
# A hook cannot invoke a skill. It injects context asking the session to; complying is
# the model's call. Asks once per pushed commit, and not at all when a push only
# lands merges.

set -eu

payload="$(cat)"

command -v git >/dev/null 2>&1 || exit 0

# The command stays JSON-escaped, which the patterns below do not mind; only `\n`
# is turned back into a separator, so a chained command still reads as one.
cmd="$(printf '%s' "$payload" | sed -nE 's/.*"command"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)".*/\1/p' | sed 's/\\n/ /g')"
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
# quiet AND leave the record alone, so the successful retry still nudges.
upstream_sha="$(git rev-parse '@{u}' 2>/dev/null)" || exit 0
[ "$upstream_sha" = "$head_sha" ] || exit 0

# Each upstream keeps the last HEAD whose pushed commits were accounted for, nudged
# or not, so a later push asks only about what is new since. Per upstream, because
# every worktree pushes its own branch into this same git dir. Flat names, `/` as
# `:` which no ref may hold, so `fix` and `fix/foo` never fight over a path.
upstream_ref="$(git rev-parse --symbolic-full-name '@{u}' 2>/dev/null)" || exit 0
state="$git_dir/whiska-reflect/$(printf '%s' "$upstream_ref" | tr '/' ':')"

# Where to count from: that record when HEAD still descends from it, else where the
# upstream sat before this push, from the remote-tracking reflog. Neither → nudge.
base=""
if [ -f "$state" ] && git merge-base --is-ancestor "$(cat "$state")" HEAD 2>/dev/null; then
  base="$(cat "$state")"
else
  base="$(git rev-parse -q --verify "$upstream_ref@{1}" 2>/dev/null)" || base=""
fi

{ mkdir -p "$git_dir/whiska-reflect" && printf '%s' "$head_sha" > "$state"; } 2>/dev/null || true

# A branch reflects before it finishes, so a push that only lands merges is work
# already reflected on: walk first parents over what is new and stay quiet when
# every one is a merge, since the branches' own commits sit behind second parents.
# A squash or fast-forward leaves no merge and nudges — noisy beats silently off.
if [ -n "$base" ]; then
  written="$(git rev-list --first-parent --no-merges "$base..HEAD" 2>/dev/null)" || written="x"
  [ -n "$written" ] || exit 0
fi

cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"A push just landed. Before starting anything new, run both reflection skills on what was pushed — this is a standing rule in this repo's CLAUDE.md, not a suggestion from the diff:\n\n1. `lesson-learned` — on the commits just pushed. Keep what it surfaces; discard nothing silently.\n2. `domain-modeling` — check whether this change introduced, renamed, or sharpened any domain term (update CONTEXT.md) or settled a decision that meets the ADR bar (add to docs/adr/, update its README index).\n\nIf either turns up nothing worth writing down, say so in one line and move on. Do not skip them silently."}}
JSON
