# A session's rules arrive at session start, by its role, as rules not prose

A `SessionStart` hook prints the rules a session's role needs, as
`hookSpecificOutput.additionalContext`, and nothing else reaches it: no block in
`CLAUDE.md`, no rule for the other role. Everything that takes judgment — what is worth
escalating, what a mouse may do, how it reports — lives in those plain rules, which a
capable model reads. Whiska itself routes and stores and decides nothing: no scoring, no
algorithm, only a short list of hard rules the hooks enforce (ADR-0011) and written rules
for the rest.

| Role | How it is read | Parts |
| --- | --- | --- |
| Outside herdr | `HERDR_ENV` is not `1` | none |
| Main session | in herdr, and not a mouse | `worktrees` (routing), `work`, `delivery`, `writing` |
| Mouse | started in a `worktrees/<branch>` worktree, not in the recorded main pane (ADR-0053) | `work`, `marker`, `report`, `writing`, `finish` |

A mouse whose `SessionStart` carries `source` `compact` gets one more line after its
rules, fixed text and nothing parsed: "You were just compacted. Before continuing, read
.whiska-spec.md if it exists, run git status, and run whiska questions to see what was
asked and answered." The main session, and a mouse that starts, resumes or clears, get
no such line. The compaction summary is Claude Code's and can lose what the mouse was
told; these commands read the spec, the work and the questions back from disk.

`work` is the order every piece of work goes in — done, grill, spec, build — and what
counts as costly; both roles need it, since the main session follows it when the person
says to work in place. `writing` is how every session writes to the person, and both
roles get it too. Claude Code runs the hook on startup, resume, `/clear` and
compaction, so a compacted session is told its rules again. A session with no transcript
yet is placed by `CLAUDE_PROJECT_DIR`, never by its working directory, which follows every
`cd` (ADR-0053). The global shim exits before starting Whiska when `HERDR_ENV` is unset,
and stands down in a repo that wires Whiska itself, as for every hook (ADR-0056).

## Rules, not prose

Each part is a short lead saying who the rules bind and when, then one bullet per rule. A
line earns its place by being an imperative or a concrete fact — a command, a path, a
marker spelling. Rationale stays in these records; a consuming repo has no pointer to them,
because its reader only needs what to do. The one exception is a reason without which a
rule would be misapplied: "never `herdr agent prompt` into the pane" keeps "only
`whiska reply` frees the one delivery slot", because a session that does not know about
the slot reaches for the pane the moment it looks faster.

A rule that matters at one moment ships as a skill rather than as rules: the finish
pipeline (ADR-0049) is `whiska-finish`, loaded only as a turn ends, and the `finish` part
names the trigger and nothing more. The `work` part does the same for grilling and the
spec: it names `grilling` and `whiska-spec`, and adds only what is a mouse's own — the
costly-versus-cheap test, the four briefs that skip the spec, and the decision marker
(ADR-0063). How to grill a build from a Proposed build, and what a sniff mouse grills, are
in the `grilling` skill, the moment they matter. A skill keeps a section it rarely needs in a file
beside it — `whiska-delivered` reads `finished.md` and `sniff.md` only when the line says
finished — and `whiska init` ships every Markdown file beside a skill's `SKILL.md`.

The `report` part is the shape of a mouse's final message: the five-item order, its size,
the leave-out list and when to ask. The `writing` part is how any session writes to the
person: the recap line, a term defined the first time, the problem first in one plain
sentence, problem and risk labelled, the decision brief, numbered questions each with a
recommended letter, a reply under about fifteen lines. Its rules come from the person's
own replies across 416 sessions. The top complaints were a term never defined (about 60),
the problem never said in one plain line (about 50) and no clear next step (about 22);
length mattered only past about 40 lines, where confused replies doubled. Those rules
used to live in the person's own `CLAUDE.md`, where they could not speak to Whiska's
shapes, and the two disagreed: one question at a time there, every costly choice in one
round here. Numbered questions settle it, since that is what the person answered fastest.
A person who wants their own wording marks the part `keep`.

## `keep` is the person's claim on a part

A part's name is load-bearing: it is what `keep` names. A start marker
`<!-- whiska:<name>:start keep -->` in a `CLAUDE.md` the hook trusts holds that part as
the person's, and the hook leaves it out of what it prints, since their wording is already
in context. The repo's own install trusts `~/.claude/CLAUDE.md` and the project's
`CLAUDE.md`; the global install, which runs in every repo the person opens, trusts
`~/.claude/CLAUDE.md` alone — two comment lines in a cloned repo would otherwise silently
drop a mouse's finish and marker rules, and they do not show when the file is rendered.

`keep` exists because "a person can drop a part" and "init adds parts that are missing"
contradict each other without a third thing: delete the part and the next run puts it
back. Dropping a part is emptying it and marking it `keep`, which reads as a decision in
the file rather than as an absence somebody has to remember.

`whiska init` takes an older install's block out of a `CLAUDE.md`, in both scopes,
through a symlink like every write (ADR-0056): Whiska's header and every part not marked
`keep` go; a `keep` part and the person's own text inside the markers stay; with nothing of
theirs left, the outer markers go too. A file with no block is untouched, and no
`CLAUDE.md` is created. `whiska uninstall` shares the code. The old block's grammar — one
outer `<!-- whiska:start -->` pair, a named pair per part, a marker a whole line of its
own — is still how an old block is read.

## Six one-word skills never load

`inbox`, `dismiss`, `away`, `focus`, `hold` and `resume` carry
`disable-model-invocation`: their slash commands work, and no session — a mouse's
included, where the hook refuses them anyway — pays for their descriptions. `show` and
`reply` stay where the main session can reach them after a delivered question (ADR-0022).

## Why

The block was about 2,400 tokens, loaded in every session on the machine once the global
install existed, and most of those sessions could not use a line of it: outside herdr
nothing is spawned or delivered, and inside it each role read the other's rules. By five
parts the prose had reached 3,300 words, most of it motivation for rules the session would
follow either way, and the finish pipeline alone was 58% of it.

## Considered options

- **Keep the block and gate it in prose** ("outside herdr, ignore this"). A line telling
  the model to ignore 2,400 tokens still costs the 2,400 tokens.
- **One injection for every herdr session.** Saves only the non-herdr sessions; each role
  still reads the other's rules.
- **Drop `keep`.** It is the one way a person rewords or silences a part, and honouring it
  costs reading two files the session loads anyway.
- **A config file listing which parts to write.** It would disagree with the `CLAUDE.md`
  it describes, and a person editing that file could not tell something else had an
  opinion about it. The marker sits where the person is already looking.
- **Leave an unshipped part where it is.** Every rule would reach the session twice.
- **Make the six one-word skills plain `!` commands, or drop them.** The person can type
  `! away` already; dropping the slash commands would take away `/away`.
- **Leave the voice rules in the person's `CLAUDE.md`.** A session outside herdr keeps
  them, but they cannot speak to Whiska's shapes, and every other Whiska user's sessions
  would write however Claude writes by default.
- **A `~/.whiska` config holding the person's voice rules.** Six lines in a file the
  session cannot see without Whiska copying them in anyway.
- **A persistent sub-supervisor layer** between Whiska and the mice. Overkill for one
  person's projects.

## Consequences

- Outside herdr a session gets nothing, including the grill, spec and finish steps and
  the writing rules.
- The rules are not in a file the person can open. `whiska hook session-start` prints
  them, and `whiska doctor` fails a repo whose `SessionStart` is not wired. A per-repo
  install still travels with the repo: the hook entry is in its committed `settings.json`.
- Each role's rules stay well inside the 10,000 characters Claude Code keeps of one
  injection; a test holds each under 7,000.
- A new rule arrives as a bullet, its reasoning as an ADR, and a rule that applies at one
  moment as a skill. Tests pin behaviour, not sentences, plus a ceiling on length, so the
  next accretion fails a test rather than landing quietly.

Folded in on 2026-10-08: 0017, 0045, 0055 (their text is in git history).
