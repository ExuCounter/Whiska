# Whiska stands alone: it builds on Claude Code, herdr and git, and calls nothing else on the machine

Whiska's rules and shipped skills call only what Whiska ships, plus Claude Code and its
built-in agents, herdr, git and the platform's service manager. Everything else on the
person's machine — their own skills, plugins, agent packs, viewers, link handlers and
scripts — is theirs to opt into and never built in: Whiska names none of it. A test reads
the rules and every shipped skill, and fails on a "`<name>` skill" Whiska does not ship, a
"`<name>` agent" or `agent:` line Claude Code does not ship, or a known outside tool by
name; wording that slips past those patterns is the cold review's to catch.

Opting in goes through text the person or the repo already owns: the person's own
`CLAUDE.md`, a reviewer named there included, and a repo's `.claude/agents/*-reviewer.md`
and its `reviewers:` line under `## Finish` (ADR-0049). A forge's command-line tool, `gh`
or `glab`, runs only when the person picks "Open a merge request / PR", and its absence is
said plainly.

## What went

- **wio's test scout and test reviewer.** The scout ranked what was worth testing before
  a build and the reviewer judged each written test at finish. A mouse now names its own
  failing test (ADR-0063), the cold review reads test changes like any other change, and
  finishing has no tests axis.
- **The frontend-preview step** in the `work` part, which leaned on the person's own
  `frontend-preview` skill.
- **"Prefer a reviewer somebody else maintains."** Finishing took any agent the session
  listed that looked built for an axis, so a plugin installed for something else could
  review Whiska's work. The mouse now writes each axis's prompt for Claude Code's
  `general-purpose` agent, the cold review aside, and the repo's own agents add axes.
- **`hunk diff`**, printed above a finished branch's options. In its place `whiska show`,
  run from the main checkout, writes the branch's diff, `git diff <base>...<branch>`, to
  `.whiska/reviews/<id>.md`, ignored like the kept specs (ADR-0063), and prints a link to
  it under the branch line, as a spec goes to the person as a link. Run from a mouse's
  worktree it writes nothing, since a mouse never writes to the main checkout. The file is
  Markdown, so it opens in whatever the person's links open in. No diff program, text
  conversion or submodule diff that git's config names runs, and the write never follows a
  link. A person who wants hunk asks for it in their own `CLAUDE.md`.

One older call stays, named so this record is not read as already true everywhere: the
owl's desktop notification uses `terminal-notifier` when it is installed (ADR-0062).

## Why

Whiska is to be open source, and a tool that quietly calls its author's other tools works
on one machine. wio cost every mouse 550 characters of rules for a pack most machines will
not have, and "not listed → say so in one line" made its absence look handled when the
step was simply missing. The person's own tools still work with Whiska; they plug in from
the person's side.

## Considered options

- **Keep each integration, with a "not listed" fallback.** What the wio wiring did; every
  fallback is a line each session reads, for a tool most never have.
- **A `.whiska.json` for global and per-repo settings,** naming the outside tools to call.
  Not ruled out: how opting in should look beyond `CLAUDE.md` is an open question for its
  own research. ADR-0081 turned down a `~/.whiska` config for voice rules alone.
- **A tests axis on a prompt Whiska writes.** One more agent on every turn that touches a
  test, where the cold review already asks what each hunk promises that no test asserts.
- **A plain `git diff` command in place of the link.** A command has to be typed; a link
  opens where the person already reviews a spec.

## Consequences

- No mouse scouts before a build, and finishing has four axes.
- Showing a finished question with commits from the main checkout writes its diff file,
  rewritten on each show. Nothing removes the folder: it holds one file per question
  shown, and a secret a branch once committed stays in its file after the branch is
  dropped.
- A rule or shipped skill that names an outside tool fails a test.

Folded in on 2026-10-11: 0075 (its text is in git history).
