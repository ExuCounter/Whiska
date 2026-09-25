# Answers are keyed to a question id, not a branch

The original relay had no correlation between a reply and the question it answered: if a
branch had two open questions at once, an answer landed on whichever one the system
guessed. That mismatched-answer problem is the reason this project exists, so `whiska
reply` and `whiska diff` take a question id — a plain incrementing number, global within
this repo's house — rather than a branch name.

## Consequences

Commands that act on a worktree or mouse as a whole, not on one specific question, still
take a plain branch name: `whiska reopen`, `whiska cleanup`. There is no ambiguity there,
since a worktree has one branch checked out at a time. Branch stays a convenient lookup
against whatever is currently live, never how anything is stored.
