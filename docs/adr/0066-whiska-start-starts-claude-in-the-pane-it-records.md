# `whiska start` starts Claude in the pane it records

Setting a house up took two commands in a fixed order: start Claude Code in a pane, then
`! whiska start` from inside it — or run `whiska start` in a shell first and then remember
to start Claude there. The help said outright that `start` "does not launch Claude Code
itself yet". Getting the order wrong is one of the ways a repo ends up with no main session
at all, which is the failure ADR-0065 exists to make visible.

## Decision

**`whiska start` records the pane and then starts Claude Code in it, when nothing is
running there.** One command. The discriminator is the question Whiska already asks herdr
about that pane: a pane herdr says is running Claude is recorded and left alone — which is
exactly what `! whiska start` from inside a session does today — and a pane herdr says is
running nothing is recorded and handed to Claude.

"Running nothing" is herdr's answer, not an inspection of the pane: a pane sitting in
`vim`, in `psql` or on a password prompt also reads as no agent, and the line would be
typed into that. It is the right reading anyway — the person just typed this command in
that pane, so the prompt is theirs — and a pane running Claude, the one case where typing
would land inside somebody's conversation, is exactly the case this refuses.

**`--no-claude` records and starts nothing**, for a script, and for a person who means to
start Claude themselves. It is the escape hatch, not the default: a recorded pane with no
Claude in it was never anybody's goal, it was the gap.

**The pane is recorded first, and the launch is the last thing the command does.** This is
forced by the mechanism and is also the right failure to choose. `whiska start` is itself
what is running in the pane it is recording, so starting Claude means handing the pane over
and getting out of the way: the line is typed at the shell prompt, waits there while this
process finishes, and runs as it exits. Nothing of Whiska's can run after it.

The failure that order chooses is **a pane recorded with no Claude in it**. The other order
chooses **Claude running in a pane that was never recorded** — a session that looks like
the whiska and is not, silently, which is the exact thing this pair of changes is about.
The recorded-but-empty pane is the loud one: the person is sitting in that pane watching the
shell say what went wrong, `whiska start` can simply be run again, the owl logs that the
main session's pane is not running Claude, `whiska doctor` warns the same, and nothing is
lost — the questions stay queued (ADR-0008). When herdr refuses the line, the command says
so, exits non-zero, and says the recording stands.

**`--force` is untouched, and agrees with this.** The refusal is about replacing *another*
pane that is still running Claude; the launch only ever happens in *this* pane, and only
when this pane has no Claude. Both ask it through the same predicate over the same
`pane.get` call — on two different panes — so they cannot disagree about what "running
Claude" means.

**It is typed into the pane's shell, through herdr** (`pane.send_text`, behind the boundary
of ADR-0031, like everything else herdr does for Whiska). Typed rather than executed,
because the person's own `claude` may be a shell function, an alias or a wrapper on their
`PATH`, and typing the line is what they do by hand today. This is the second thing Whiska
types anywhere, after delivery (ADR-0044) — and unlike delivery it is the person's own
command, in the person's own pane, in the breath they asked for it.

**It is not a `whiska spawn`.** ADR-0021 refused a command that spawns a *mouse*, because
which mode, which model and whether the work deserves a worktree are judgment calls that
belong in a conversation. None of that applies here: there is one main session per house,
it lives in the main checkout, and the pane is already chosen — it is the one the command
was run in. ADR-0020 still holds too: herdr starts Claude Code, Whiska does not own the
process, and the result is a herdr pane like any other.

## Consequences

**The command's own exit does the launching.** herdr buffers the typed line until the shell
prompt comes back, which is why a command that holds the pane can still start something in
it. Verified against herdr 0.8.2: a line typed into a busy pane runs when the prompt
returns.

**Whiska never learns whether Claude actually came up.** It cannot wait for it without
holding the pane it has to release. What happens instead is that the person sees it — they
are in that pane — and every other place that cares already reports it: the owl's log, the
doctor's main-session warning, and the board, which is drawn by Claude Code and so is
missing entirely while Claude is not running.

**`whiska start` now needs herdr for more than the pane id.** With no socket it records the
pane and says it could not start Claude; the recording is the half that matters and it
still happens. Inside a session that is already running, nothing changed at all — there is
nothing to start.

**It will not resurrect a dead session into the same pane twice.** Run it in a pane where
Claude is already running and it records and stops; that is the only safe reading, and the
person who wants a second session makes a second pane.
