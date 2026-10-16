# Whiska stands alone: it builds on Claude Code, herdr and git, and calls nothing else on the machine

Whiska's briefs and commands call only what Whiska ships, plus Claude Code and its
built-in agents, herdr, git and the platform's service manager. Everything else on the
person's machine — their own skills, plugins, agent packs, viewers, link handlers and
scripts — is theirs to opt into and never built in: Whiska names none of it. No test reads
the briefs for names, since tests pin what Whiska does and not its sentences
(ADR-0088); a name that slips into a brief is the cold review's to
catch.

Opting in goes through text the person or the repo already owns: the person's own
`CLAUDE.md`, a reviewer named there included, and a repo's `.claude/agents/*-reviewer.md`
and its `reviewers:` line under `## Finish` (ADR-0049). What Whiska itself prints for the
person to review, which no `CLAUDE.md` line can change, is a link to a file, and the person
opts in where every file's viewer is chosen: their terminal's open actions, or their OS's
app for that file type, `.md` for a document and `.diff` for a diff (below). No link
Whiska prints for review reads the environment. A forge's command-line tool,
`gh` or `glab`, runs only for something the person asked of a merge request, and its
absence is said plainly. The cases so far:

- **Opening one:** the person says "pr", and the main session runs `whiska pr`, which
  pushes the branch by its name and opens the request. It is assigned to the account the
  tool is signed in as, the account that is also its author.
- **Reading one Whiska recorded:** while a GitLab merge request the person had opened
  waits, the owl reads it every minute through `glab api`, `GET` only, to show it on the
  mouse's row and to see it merge or close (ADR-0060). Without `glab`, nothing is read and
  `whiska doctor` says so.
- **Handling its review:** a review round's mouse reads every open thread, fixes, answers
  or disputes each, and writes its replies to files. On the person's yes the main session
  runs `whiska push`, which pushes the branch and posts each reply through `glab api`
  under the person's account, resolving the threads the mouse fixed (ADR-0060). No mouse
  writes to the forge.
- **Showing one in the browser:** `whiska merge-request open`, from a key the person binds
  in their own herdr config, runs `gh pr view --web` or `glab mr view --web` on the
  merge request of the mouse whose worktree holds the focused pane's directory. herdr's
  sidebar cannot carry a link (ADR-0082), so the key is the way there.

## What went

- **wio's test scout and test reviewer.** The scout ranked what was worth testing before
  a build and the reviewer judged each written test at finish. A mouse now names its own
  failing test (ADR-0063), the cold review reads test changes like any other change, and
  finishing has no tests axis.
- **The frontend-preview step** in the mouse's rules, which leaned on the person's own
  `frontend-preview` skill.
- **"Prefer a reviewer somebody else maintains."** Finishing took any agent the session
  listed that looked built for an axis, so a plugin installed for something else could
  review Whiska's work. The mouse now writes its reviewers' prompts for Claude Code's
  `general-purpose` agent.
- **`hunk diff`**, printed above a finished branch's options. In its place `whiska show`
  writes the branch's diff, `git diff <base>...<branch>` exactly as git prints it, to
  `.whiska/reviews/<branch>-<hash>.diff`, one file per branch (the name made safe for a
  file and cut to 100 characters, and 128 bits of a hash of the whole name, so `feat/x`
  and `feat-x` keep a file each and no mouse can search out a name that shares another
  branch's file), with its last review round's change beside it as `.round.diff`
  (ADR-0089),
  ignored like the kept specs (ADR-0063), and hands a link to it over among its links
  (ADR-0089), as a spec goes to the person as a link. It writes the file wherever it runs,
  a mouse's worktree included: the main session's shell can stand in a worktree, and a
  read that wrote nothing from there dropped the link without a word. The folder is
  Whiska's own and ignored, so a write from a mouse costs nothing. No diff
  program, text conversion or submodule diff that git's config names runs, and the write
  never follows a link. The file goes when Whiska deletes the branch, on `whiska drop` or
  on cleanup once the branch has landed. The file is a plain patch, so it opens wherever
  the person's `.diff` files open: a person who wants hunk, or any diff viewer of their
  own, points that file type at it in their terminal's open actions or their OS, as they
  point `.md` at their document reviewer. Whiska still names no viewer.
- **The spec and build plan links are file links too.** `whiska show` hands them over
  among its links, for the spec and the build plan the mouse's worktree
  holds, as it does the diff's; the mouse pastes no link (ADR-0063). They open wherever
  the person's `.md` files open.

The one older call, `terminal-notifier` for the owl's desktop notification, was dropped on
2026-10-11 (ADR-0062) and came back on 2026-10-15 as an optional first choice on macOS: a
public tool, never required, since the hoot falls to `osascript` without it, and to
`notify-send` on Linux.

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
  own research. ADR-0081 turned down a `~/.whiska` config for voice rules alone. Choosing a
  viewer did not wait for it, and needs no setting of Whiska's: the file type is the
  setting.
- **Link patterns in the environment, `WHISKA_DIFF_LINK` and `WHISKA_SPEC_LINK`,** tried
  from 2026-10-11 to 2026-10-14. A variable reaches only a process that read the person's
  shell profile, and the main session's shell, which runs `whiska show`, had not: the link
  fell back to the file without a word. And a pattern's own scheme, such as
  `hunk-review://`, opens only in a terminal the person has taught it to, so the setting
  served one machine.
- **The same pattern in git's config,** `whiska.diffLink`. It reaches every process, but
  its scheme still opens only where the person taught their terminal it.
- **A `whiska://` scheme Whiska registers with the OS,** its handler opening a live diff in
  a herdr tab. Install code for each platform (a generated macOS app, a Linux `.desktop`
  entry), and a handler any web page can ask to open.
- **`whiska diff`, opening the diff in a herdr tab through git's pager on a word to the
  main session.** The person reviews from a link, not a word.
- **A Markdown copy of the diff,** what the file was until 2026-10-14. It opened in the
  document reviewer, a poor place to read a diff.
- **A tests axis on a prompt Whiska writes.** One more agent on every turn that touches a
  test, where the cold review already asks what each hunk promises that no test asserts.
- **A plain `git diff` command in place of the link.** A command has to be typed; a link
  opens with one click, wherever the person's files of its type open.

## Consequences

- No mouse scouts before a build, and finishing has no tests axis.
- Showing any question whose branch has commits writes its diff file, from wherever it runs,
  rewritten on each show, so the file is the branch as it stood when last shown. Whiska
  removes a branch's file when it deletes the branch; a branch deleted by hand, a removal
  that fails (a linked folder is refused), or a show still writing as the branch goes
  leaves its file, and with it any secret the branch once committed. A failed removal
  never fails the drop or the cleanup: the branch is gone either way. A branch whose
  commits add up to no change hands over no whole diff and keeps no file, and neither does a
  diff git cannot print, such as one that needs a blob a partial clone left out: Whiska
  never fetches for a show.
- A person who has pointed `.diff` at nothing reads the patch in whatever their OS opens
  it with. Whether a file link reaches them clickable is up to Claude Code and their
  terminal, not Whiska.
- A brief that names an outside tool is caught by review, not by a test.

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

Changed on 2026-10-12: the diff file is one per branch, not one per question, so an
earlier question's link opens the branch's diff as it stands, not the diff as it was.

Folded in on 2026-10-11: 0075 (its text is in git history).

Changed on 2026-10-13: `whiska pr` opens a merge request on the person's word, the build
brief handles its review, `whiska show` prints the spec and build plan links itself, and no
test scans the briefs for names (ADR-0088).

Changed on 2026-10-14: every review link `whiska show` prints is a file link, and the
diff is a `.diff` patch that opens wherever the person's `.diff` files open.
`WHISKA_DIFF_LINK` and `WHISKA_SPEC_LINK` went: only a process that had read the person's
shell profile saw them, so the main session printed the file link instead. A branch's
diff file now goes with the branch.

Changed on 2026-10-14: the owl reads a recorded GitLab merge request through `glab`, the
one call to a forge the person did not ask for each time; opening it is what asked
(ADR-0060).

Changed on 2026-10-14: `whiska merge-request open` shows a recorded merge request in the
browser through `gh` or `glab`, on the person's key.

Changed on 2026-10-15: a review round's replies are posted by `whiska push` on the
person's yes, where the mouse posted them itself (ADR-0060).
