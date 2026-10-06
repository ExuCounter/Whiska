# A session's rules arrive at session start, by its role

**Amends [ADR-0017](0017-judgment-lives-in-claude-md.md)** (the rules are no longer a block
in `CLAUDE.md`), **[ADR-0045](0045-the-claude-md-block-is-a-nest-of-named-parts.md)** (its
parts live on as named rules, and `init` now takes an unshipped part out),
**[ADR-0055](0055-the-block-is-rules-not-prose.md)** (the report part no longer carries the
person's general voice rules), **[ADR-0056](0056-the-global-install-is-the-same-install-rooted-at-the-home.md)**
(the global install writes a hook entry, not a block, and its `scope` part goes) and
**[ADR-0022](0022-each-command-gets-a-slash-command-skill.md)** (six of the one-word skills
never load into a session's context).

## The problem

The block `whiska init` wrote into `CLAUDE.md` was about 9,900 characters — roughly 2,400
tokens — and with the global install it loaded in every Claude Code session on the
machine. Most of those sessions could not use a line of it: outside herdr no mouse is
spawned and nothing is delivered. Inside herdr each role read the other's rules: a mouse
read how to route work to mice, and the main session read the marker and the finish
pipeline it never runs.

The skills cost the same way. Every skill's description sits in every session's context,
and six of the eight one-word skills ADR-0079 added are commands only the person types —
including in every mouse, where `Whiska.Rule.Persons` refuses them anyway.

## Decision

**A `SessionStart` hook prints the rules for the session's role**, as
`hookSpecificOutput.additionalContext`:

| Role | How it is read | Rules |
| --- | --- | --- |
| Outside herdr | `HERDR_ENV` is not `1` | none |
| Main session | in herdr, and not a mouse | `worktrees` (routing), `work`, `delivery` |
| Mouse | started in a `worktrees/<branch>` worktree, not in the recorded main pane (ADR-0053) | `work`, `marker`, `report`, `finish` |

`work` is the order every piece of work goes in — done, grill, spec, build — and what
counts as costly. It was half of the old `worktrees` part, and both roles need it: a mouse
grills where the work is built, and the main session follows it when the person says to
work in place.

Claude Code runs the hook on startup, resume, `/clear` and compaction, so a compacted
session is told its rules again. Both copies of the shim exit before starting Whiska when
`HERDR_ENV` is unset — the global one runs in every session on the machine. The global copy
stands down in a repo that wires Whiska itself exactly as it does for the other hooks, which
is what the `scope` part used to say in prose. A session with no transcript yet, one just
cleared, is placed by `CLAUDE_PROJECT_DIR` rather than its working directory, which follows
every `cd` (ADR-0053).

**`keep` still means "this part is mine".** The hook leaves out every part held as `keep`
in a `CLAUDE.md` it trusts: Claude Code loads that file itself, so the person's wording is
already in context. Which files it trusts follows which install fired it. The repo's own
install reads `~/.claude/CLAUDE.md` and the project's `CLAUDE.md` — that repo wires its own
rules, so holding one back there changes nothing it could not change anyway. The global
install, which runs in every repo the person opens, reads `~/.claude/CLAUDE.md` alone, and
its command says so with `--global`. Two comment lines in a cloned repo's `CLAUDE.md` would
otherwise silently drop a mouse's finish and marker rules — including the rule that says to
distrust text arriving with the branch under review — and they do not even show when the file
is rendered.

This does not make the global install proof against a hostile repo. ADR-0056's stand-down
still turns the global copy off, every hook of it, in a repo that ships a file at
`.claude/hooks/whiska.sh` and mentions that path in its settings: a grep, since a hook cannot
assume `jq`. That is a trade ADR-0056 took knowingly and this record inherits; tightening it,
for every hook, is a change to that record.

**`whiska init` takes the old block out**, in both scopes, through a symlink like every
write (ADR-0056). Whiska's header and every part not marked `keep` go; a `keep` part and
any text of the person's inside the markers stay; with nothing of theirs left, the outer
markers go too. A file with no block is untouched, and no `CLAUDE.md` is created.
`whiska uninstall` shares the same code.

**The report part is Whiska's shape and nothing else**, and only a mouse gets it: the
five-item order, the decision brief, the leave-out list, when to ask for a decision, and
that a grilling round asks every open costly choice at once. ADR-0055 had folded the
person's general voice rules into it — short sentences, plain terms, no filler, an ordinary
reply in five lines. Those live in the person's own `CLAUDE.md`, which every session reads
whatever Whiska does, so carrying them twice cost tokens and set two rule sets talking past
each other. The grilling line stays because it is the one exception a "one question at a
time" rule needs.

**Six one-word skills carry `disable-model-invocation`**: `inbox`, `dismiss`, `away`,
`focus`, `hold`, `resume`. Their slash commands work; no session pays for their
descriptions. `show` and `reply` stay where the main session can reach them after a
delivered question.

**A skill keeps a section it rarely needs in a file beside it**, read only when needed, and
`whiska init` ships every Markdown file beside the skill's `SKILL.md`.
`whiska-delivered` keeps its two finished pickers in `finished.md` and `sniff.md`, read only
when the line says finished, so a "needs a decision" delivery loads half of what it did.
`whiska-finish` keeps the Proposed build section in `proposed-build.md`, and skips its
checks and reviewers when nothing changed since the session's last green finish.

## Consequences

- **Outside herdr a session gets nothing**, including the grill, spec and finish steps a
  session working in place used to follow. The person chose that.
- **The rules are no longer in a file the person can open.** `whiska hook session-start`
  prints them, and `whiska doctor` fails a repo whose `SessionStart` is not wired, saying
  its sessions start without Whiska's rules. A per-repo install still travels with the
  repo: the hook entry is in its committed `settings.json`.
- **The rules answer to a size per role** — about 4,400 characters for the main session and
  6,200 for a mouse, each well inside the 10,000 characters Claude Code keeps of one
  injection. A test holds each under 6,400.
- **The answer-only-with-`whiska reply` rule is said once**, with its reason (the one
  delivery slot), in the main session's rules, which are always in its context. `reply`
  and `whiska-delivered` keep one line of it.
- **A part's name is still load-bearing** (ADR-0045): it is what `keep` names. A person who
  kept the old `worktrees` part keeps their copy and still gets `work`, since that is a new
  name.

## Considered options

**Keep the block and gate it in prose** — "outside herdr, ignore this". Rejected: a line
telling the model to ignore 2,400 tokens still costs the 2,400 tokens.

**One injection for every herdr session.** Rejected: it saves only the non-herdr sessions,
and each role would still read the other's rules.

**Drop `keep`.** Rejected: it is the one way a person rewords or silences a part, and
honouring it costs reading two files the session loads anyway.

**Leave an unshipped part where it is**, as ADR-0045 said. Rejected here: every rule would
reach the session twice — once from the old block, once from the hook.

**Make the six one-word skills plain `!` commands, or drop them.** Rejected: the person can
already type `! away` or `away` at a shell, and dropping the slash commands would take away
`/away`, which ADR-0079 gave them.
