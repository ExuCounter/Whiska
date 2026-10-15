# A mouse starts in bypass mode, with its mode's deny list

`whiska shape`, and so `whiska spawn`, starts every mouse in Claude Code's bypass mode,
`--dangerously-skip-permissions`, with one short deny list in a settings file of its own,
`--settings .whiska-settings.json`. The shape writes that file at the worktree root, where
git ignores it, and rewrites it on every shape. It holds:

- **For every mouse, the person's commands** (ADR-0079): `away`, `hold`, `focus`,
  `resume`, `reply`, `dismiss` and `close`, with `whiska` in front or bare, and
  `whiska spawn`, `send`, `tell`, `land`, `pr`, `merge-request` and `drop`, only with
  `whiska` in front since `pr` and `send` are other programs too. Each is a plain rule, `Bash(whiska hold *)`, which
  also matches a bare `whiska hold`. Reading commands (`inbox`, `show`, `questions`,
  `waiting`, `mice`, `ledger`) are anyone's.
- **For a sniff mouse, also `Edit`, `Write` and `NotebookEdit`** by bare name, which takes
  them out of its context altogether (ADR-0069).

Claude Code enforces deny rules in bypass mode as in any other. The `PreToolUse` hook
keeps one rule, the hold (ADR-0079): the person sets it while the mouse runs, and Claude
Code reads a settings file when a session starts.

## Why

The rules the hook ran by reading text stopped honest work and still did not stop a mouse
set on getting past them. `Whiska.Shell`, 708 lines, judged every shell command against a
read-only allowlist (ADR-0034) and every path against the main checkout (ADR-0013). Each
new tool, flag or quoting form an investigation reached for was a false denial until
someone taught the allowlist about it, and an edit inside the worktree was denied for a
path-like word in its text that resolved outside it. What it bought was containment that
ADR-0024's honest limit already said is no boundary: one OS user, no sandbox, and a hook
the mouse can switch off from its own worktree.

Bypass mode is a decision of its own: **auto mode's classifier no longer runs for a
mouse.** Under auto mode the classifier judged each call again, and denied ordinary work
for looking like something else, a `claude -p` test run or a grep among them. A mouse now
runs what its deny list and the hold allow, and its brief says the rest: stay in the
worktree, never push. Bypass mode keeps Claude Code's own exceptions, such as an `rm` of
a critical path still asking first. The person's main session is untouched; only a
shaped mouse starts this way.

## What the deny list does not catch

A deny rule matches the command's own text, after Claude Code strips a short list of
wrappers (`timeout`, `nice`, `nohup`, `command`, `builtin`, `xargs`, and a few more).
`env whiska hold x`, `exec`, a full path to the binary, `bash -c`, or a nested `claude -p`
that loads no `--settings` each get round it. That is accepted on purpose, as other tools
accept it: the list keeps an honest mouse from a mistake, and nothing short of OS-level
isolation stops a determined one (ADR-0024). Claude Code before 2.1.289 also let a
leading `FOO=1` assignment past a deny rule.

A sniff mouse may still change files through a shell command or an MCP tool. Its brief
says it changes nothing; the deny list takes away the tools whose whole job is writing.

The file sits in the worktree, so a mouse can rewrite it. That takes hold only when Claude
starts there again, and a file Claude Code cannot parse starts it with no deny list at
all. `whiska shape` refuses another mode for a mouse already shaped (ADR-0074), so a sniff
mouse cannot shape itself to build, and refuses a link at the file's path, which would
write through to whatever it points at.

## A mouse nobody shaped

A mouse started by hand without `whiska shape` has no deny list and is not limited. A
mode reaches Claude only as its launch flags, which a running session cannot take, so
`whiska mode build|sniff` gives no mode: the person runs `whiska shape <mode>` in its
worktree and restarts Claude with the flags it prints.

## Considered options

- **Claude Code's sandbox.** It would make the worktree a real boundary. Left for later:
  it changes what every mouse's tools can reach, network included, and needs its own
  trial.
- **Auto mode with the deny list.** Keeps the classifier, and with it the false denials
  this removes.
- **Wider rules, `*whiska hold*`.** Also denies a grep for the words and a commit message
  quoting them, and `env` still gets round them. Rejected by the person.
- **Holding an unshaped mouse to sniff in the hook.** Without the shell judge the hook
  could only deny every call, which is the hold's job, not a mode's.

## Consequences

- Supersedes ADR-0013 and ADR-0034. `Whiska.Shell` and the persons, sniff and
  main-checkout rules are gone, and with them `Layout.unplaced/1`.
- A mouse can write anywhere its user can, the main checkout included, and run any
  command its deny list allows. Nothing detects a push (ADR-0011).
- Bypass mode shows a warning the first time it starts on a machine. Accepting it sets
  `skipDangerousModePermissionPrompt` in the person's own settings, once. Whiska does not
  check that it was accepted, and a spawn on a machine where it was not is untried.
- A shape writes `.whiska-settings.json` and adds `/.whiska-settings.json` to the main
  checkout's `.git/info/exclude`, as it does the brief (ADR-0088). A failure to add the
  line is said, and the shape goes on.
- `whiska mice` shows an unshaped mouse as `never shaped`.

Changed on 2026-10-15: `whiska tell` joins the person's commands a mouse is denied
(ADR-0044).
