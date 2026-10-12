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
and its `reviewers:` line under `## Finish` (ADR-0049). What Whiska itself prints, which no
`CLAUDE.md` line can change, is opted into through the person's environment instead: so
far only `WHISKA_DIFF_LINK` and `WHISKA_SPEC_LINK`, the diff link's and the spec link's
patterns (below). A forge's command-line tool,
`gh` or `glab`, runs only for something the person asked of a merge request, and its
absence is said plainly. The cases so far:

- **Opening one:** the person picks "Open a merge request / PR". It is assigned to the
  account the tool is signed in as, the account that is also its author.
- **Handling its review:** the person asks a mouse to handle the review on its merge
  request (the `whiska-review-replies` skill). The mouse reads every open thread, fixes
  or disputes each, pushes, replies on the thread and resolves a bot's, all under the
  person's account and without asking along the way. A person's thread is answered but
  never resolved, and a disagreement with a person goes to the person before anything is
  posted: resolving their thread, and pushing back on them, are the person's to do.

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
- **`hunk diff`**, printed above a finished branch's options. In its place `whiska show`
  writes the branch's diff, `git diff <base>...<branch>`, to
  `.whiska/reviews/<id>.md`, ignored like the kept specs (ADR-0063), and prints a link to
  it under the branch line, as a spec goes to the person as a link. It writes the file
  wherever it runs, a mouse's worktree included: the main session's shell can stand in a
  worktree, and a read that wrote nothing from there dropped the link without a word. The
  folder is Whiska's own and ignored, so a write from a mouse costs nothing. The file is
  Markdown, so it opens in whatever the person's links open in. No diff program, text
  conversion or submodule diff that git's config names runs, and the write never follows a
  link. A person who wants hunk, or any diff viewer of their own, sets `WHISKA_DIFF_LINK` to a
  link pattern their terminal opens in it, such as `hunk-review://{base}..{branch}`: the
  diff link is that pattern with the base and branch filled in, percent-encoded so no
  branch name can break the link, and no file is written. A pattern that does not start
  with a scheme, or holds a space, a parenthesis, a backslash, or a control or format
  character, is ignored and the file link stands. Whiska still names no viewer; the person's pattern does.
- **The spec link has its own variable, `WHISKA_SPEC_LINK`,** with `{path}` (the
  file's absolute path) and `{branch}` filled in, percent-encoded, under the same rules
  and fallback. Two variables rather than one because the diff needs a base and a branch
  and the spec a file path, so no one pattern serves both. A mouse sends the spec link as
  its question, so Whiska builds the line instead of the mouse typing it: `whiska
  spec-link "<title>"` prints it, and the `whiska-spec` skill has the mouse send that
  output (ADR-0063). The same pattern serves the build plan and a bug's research
  document: `whiska spec-link` prints a line for each document the worktree holds.

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
  own research. ADR-0081 turned down a `~/.whiska` config for voice rules alone. The diff
  link's one setting did not wait for it: an environment variable holding a link pattern
  is how tools usually answer "open this where I like" (`EDITOR`, `BROWSER`, and in Elixir
  `PLUG_EDITOR`), and a settings file can come later with the variable still overriding it.
- **The diff link's pattern in git's config,** `whiska.diffLink`, global with a per-repo
  override. Turned down as more to set up than one line in the shell's profile, for a
  setting that is the person's and never the repo's.
- **A tests axis on a prompt Whiska writes.** One more agent on every turn that touches a
  test, where the cold review already asks what each hunk promises that no test asserts.
- **A plain `git diff` command in place of the link.** A command has to be typed; a link
  opens where the person already reviews a spec.

## Consequences

- No mouse scouts before a build, and finishing has four axes.
- Showing a finished question with commits writes its diff file, from wherever it runs,
  rewritten on each show, unless `WHISKA_DIFF_LINK` names a viewer. Nothing removes the
  folder: it holds one file per question shown, and a secret a branch once committed stays
  in its file after the branch is dropped.
- `WHISKA_DIFF_LINK` is read by the process that runs `whiska show`, so a Claude Code
  session started before the person set it keeps printing the file link until it is
  restarted. Whether a link with the person's scheme reaches them clickable is up to
  Claude Code and their terminal, not Whiska. `WHISKA_SPEC_LINK` is read the same way, by
  the process that runs `whiska spec-link`.
- A rule or shipped skill that names an outside tool fails a test.

Changed on 2026-10-11: the diff link can point at the person's own diff viewer through
`WHISKA_DIFF_LINK`; until then a person who wanted hunk could only ask for it in their own
`CLAUDE.md`.

Changed on 2026-10-11: the spec link can do the same through `WHISKA_SPEC_LINK`.

Changed on 2026-10-12: the spec link pattern serves the build plan and a bug's research
document too (ADR-0063).

Changed on 2026-10-12: the forge tool runs for a list of cases the person asked for, not
only "Open a merge request / PR": handling a merge request's review joined it, and an
opened one is assigned to the signed-in account. Before, a mouse asked to handle review
skipped automated reviewers' comments and asked whether to reply.

Folded in on 2026-10-11: 0075 (its text is in git history).
