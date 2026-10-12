# Reference

Everything the README leaves out: every command, the scripting interfaces, the environment variables.

## Commands

```
whiska questions [<id>|--full]  what is waiting on you in this repo
whiska reply <id> <text>        answer — saved, then handed to that mouse by its own hook
whiska close <id>               settle one by hand, with no answer
whiska waiting [--json]         the same, across every repo on the machine
whiska jump [<repo|branch>]     focus the session of whatever needs you most

inbox                           one word each, installed by `whiska init --global`
show [<id>]                     under ~/.whiska/bin and as slash commands in the main
reply <id> <text>               session: inbox = waiting, show = the question delivered
dismiss <id>                    to you, dismiss = close; the long names keep working
away                            nothing is delivered anywhere until `resume`
focus <branch>                  only that mouse's questions reach this repo's session
hold <branch>                   that mouse stops where it is; `resume <branch>` lifts it
resume [<branch>]               end away and focus, or lift one hold; oldest first
whiska watch                    the lines herdr's sidebar shows for this repo, printed once
whiska mice                     what is alive here — branch, mode, pane, uptime, pickups
whiska worktrees                linked worktrees, their herdr workspace and pane, tab-separated
whiska where                    where this directory is, as one line of JSON, for hooks
whiska doctor                   check this repo end to end; exits 1 on any failure
whiska statusline               the tab-bar line
whiska mode [build|sniff]       this mouse's mode; build|sniff gives one to a mouse nobody
                                shaped, and refuses on one that has it. sniff writes only
                                its research document
whiska init [--global]          install into this repo's .claude/, or into ~/.claude
whiska uninstall [--global]     take it back out; the house is untouched
whiska start [--force]          record this herdr pane as the repo's main session, and
      [--no-claude]             start Claude Code in it if nothing is running there
whiska owl [install|start|stop|uninstall]
```

`whiska --help` has the full text for each.

### `whiska where`, for scripts

`whiska where` tells a hook or script where it runs, so it needs no copy of Whiska's
layout rules. It prints one line of JSON and always exits 0:

```
{"version":1,"worktree":"/src/app/worktrees/feat/x","branch":"feat/x","main_checkout":"/src/app","main_workspace":"w3"}
```

| Field | Meaning |
| --- | --- |
| `version` | Format version, `1`. Changes only when a field changes. |
| `worktree` | The worktree's root folder; `null` outside one. |
| `branch` | The worktree's whole branch name; `null` outside one. |
| `main_checkout` | The main checkout's folder; `null` outside both a worktree and the main checkout. |
| `main_workspace` | The herdr workspace id open on the main checkout; `null` when herdr is not running, takes over half a second to answer, or has none open. |

Every field is always present. These fields are stable: a change to them bumps
`version`. Read one with `jq -r '.main_workspace // empty'`.

### `~/.whiska/owl.sock`, for scripts

The running owl answers questions over a Unix socket, so a script can ask without
starting Whiska: a few milliseconds instead of a quarter of a second. Send one line, get
one line back, then the owl closes the connection:

```
echo waiting | nc -U ~/.whiska/owl.sock | jq -r '.waiting[] | "\(.repo)  \(.branch)  \(.pointer)"'
```

| Request | Answer |
| --- | --- |
| `waiting` | `{"version":1,"waiting":[…]}` — everything waiting on every repo, oldest first. Each row has the fields `whiska waiting --json` prints: `repo`, `main_checkout`, `branch`, `id` (`null` while still on the doorstep), `kind`, `status`, `pointer`, `age_seconds`, `pane`, `waits`, `held`. |
| `show <id> <main_checkout>` | `{"version":1,"question":{…}}` — one question: `id`, `repo`, `main_checkout`, `branch`, `kind`, `status`, `pointer`, `text` (the whole message), `asked_at` (ISO 8601). Ids are numbered per repo, so the main checkout is needed; everything after the id is the path, spaces and all. |
| `jump` | `{"version":1,"whiskas":[…]}` — every whiska `whiska jump` can land on, waiting ones first; the rows `whiska jump --list --json` prints: `repo`, `main_checkout`, `waiting`, `oldest_wait_seconds` (`null` when nothing waits), `summary`, `main_session`. |
| `questions <main_checkout>` | `{"version":1,"questions":"…"}` — the text `whiska questions` prints in that repo. Only for a repo the owl has open. |
| `line [hint]` | The tab-bar line, as plain text. A hint is added at the end when something not held is waiting. |
| anything else | `{"version":1,"error":"…"}` — `unknown request`, `no such house`, `no such question`, `unreadable house`. |

`version` is `1` and changes only when a field changes. No answer at all means the owl is
not running; `whiska waiting --json` reads the same rows without it. The socket lives
under `WHISKA_HOME` when that is set, and only your own user can open it.

## Advanced and environment

- **A repo that cannot carry a committed `.claude/`** — `whiska init --global`, once, for
  every repo on the machine. A repo that ran `whiska init` still wins there.
  [Details](internals.md#the-global-install).
- **The machine-wide tab-bar line** — `whiska owl install` writes
  `~/.whiska/herdr-status.sh` and prints a `tab_bar_right` entry; paste it into
  `~/.config/herdr/config.toml` yourself and run `herdr server reload-config`. The script
  asks the owl over `owl.sock` and starts nothing. Its one argument is the key you bound
  to reach what waits, shown when something does — `herdr-status.sh '⌃a space'` draws
  `🦉 watching · 🐱 2 whiskas · ⌃a space`; leave it off and no hint is shown.
  [Details](internals.md#wiring-the-tab-bar-and-the-sidebar).
- **`keep` on a `CLAUDE.md` block marker** — claims that part so `init` never rewrites it.
  [Details](internals.md#the-claudemd-block).
- **`WHISKA_BIN` and `WHISKA_ESCRIPT`** — override how the hook shim finds the binary and
  the Erlang runtime.
- **`WHISKA_DIFF_LINK`** — point a finished branch's `Review diff here:` link at a
  diff viewer of your own instead of the Markdown diff file. It holds a link pattern your
  terminal opens there, with `{base}` and `{branch}` filled in:
  `export WHISKA_DIFF_LINK='hunk-review://{base}..{branch}'`. Set, no diff file is
  written; a pattern without a scheme, or with a space, parenthesis, backslash or control
  character in it, is ignored.
- **`WHISKA_SPEC_LINK`** — the same for the `Review spec here:`, `Review build plan here:`
  and `Review research here:` links a mouse sends for your ok, instead of the file links
  that open in annotate. The pattern gets `{path}`, each file's absolute path, and
  `{branch}`:
  `export WHISKA_SPEC_LINK='myviewer://open?file={path}'`. The same patterns are ignored.
  Set it in your own shell profile, never from a repo's env file: a pattern decides what
  clicking the link opens.
- **What the rules actually cover** — a build mouse cannot write into the main checkout or
  the worktrees under it; a sniff mouse can write only its research document. **Neither is a sandbox**: a
  path elsewhere on the machine is allowed, reads are never policed, and only
  `Write`/`Edit`/`MultiEdit`/`NotebookEdit`/`Bash` go through the hook.
  [Details](internals.md#what-is-enforced).

