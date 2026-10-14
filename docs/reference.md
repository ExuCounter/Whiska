# Reference

Everything the README leaves out: every command, the scripting interfaces, the
environment variables. `whiska --help` has the full text for each command.

## Commands

### Questions

```
whiska questions [<id>|--full]  what is waiting on you in this repo; an id or --full shows it in full, a report as its Summary
whiska reply <id> <text>        answer it: saved, then that mouse's own hook takes it
whiska close <id>               settle one by hand, with no answer
whiska waiting [--json]         what is waiting on you in every repo on this machine
whiska open <id|branch>         go to that mouse's own pane
whiska jump [<repo|branch>]     go to the main session of whatever needs you most, or of that repo
whiska jump --list [--json]     every main session `jump` can land on, for a script
```

### One-word commands

```
inbox [--all] [--json]   what is waiting in this repo, and why each is not delivered yet
show [<id>]              the question delivered to you, or any one by id: its facts, one labelled line each, then its message
reply <id> <text>        `whiska reply`
dismiss <id>             `whiska close`
away                     nothing is delivered to any main session until `resume`
focus [<branch>]         only that mouse's questions reach this repo's main session
hold <branch>            that mouse stops at its next write or shell command
resume [<branch>]        end away and focus, or lift one mouse's hold
```

Each is also `whiska <word>`, and your main session runs it when you ask in your own
words ("what's waiting?", "I'm away"). `whiska init --global` also writes them as shell
commands to `~/.whiska/bin`: put it on your `PATH`. A word another program already
answers to is skipped. A mouse cannot run `away`, `focus`, `hold`, `resume`, `reply`,
`dismiss` or `close`, nor the commands for a branch below: its deny list refuses them
(ADR-0079).

### A branch

Your main session runs these when you say so; it picks the mode, model, effort and
branch name with you, and passes each as an argument (ADR-0088).

```
whiska spawn build|sniff <branch> <task-file>     a fresh worktree with a mouse working on the task in the file
      [--model <name>] [--effort <level>]
whiska spawn build <branch> --from <id>           build what question <id> proposes under "What to change"
      [--comments <file>]
whiska send <branch> <file>                       your words in the file, to the mouse at work on that branch
whiska land <id> [--commit <message-file>]        copy the branch's commits onto this checkout's branch, then run checks:
whiska pr <id> [--commit <message-file>]          push the branch and open its merge request, or push to the open one
whiska drop <branch> [--force]                    take down its worktree, herdr workspace and branch
whiska merge-request <id> <url>                   record a merge request opened by hand
```

### Looking at what is going on

```
whiska mice                     each mouse here: branch, mode, what its pane is doing, context used, uptime
whiska watch                    the sidebar lines for this repo, worked out now
whiska statusline               the tab-bar line
whiska metrics [--json]         cost and waiting, from this repo's house
whiska doctor                   check this repo end to end; exits 1 on any failure
```

### Setting up

```
whiska init [--global]          install into this repo's .claude/, or into ~/.claude
whiska uninstall [--global]     take it back out; the house is untouched
whiska start [--force]          record this herdr pane as the main session, and start
      [--no-claude]             Claude Code in it, with its brief, if nothing runs there
whiska owl [<repo>...]          run the owl in the foreground; the repos named are recorded
whiska owl install|start|stop|uninstall
whiska --version
```

### Called by hooks, sessions and scripts

```
whiska hook <name>              pre-tool-use, stop, user-prompt-submit
whiska where                    where this directory is, as JSON (below)
whiska worktrees                linked worktrees with their herdr workspace and pane, tab-separated
whiska shape build|sniff        give a mouse started by hand its mode, model, effort, brief and
      [--model <name>] [--effort <level>]   deny list, and print the flags to start Claude with,
                                            bypass mode among them
whiska shape --rules            the rules a spawn picks a model and an effort by
whiska mode                     this mouse's mode
whiska ledger [--json]          the agent ledger a finished report ends with
whiska base                     the branch this worktree was cut from
```

## `whiska where`

Tells a hook or script where it runs, so it needs no copy of Whiska's layout rules. One
line of JSON, always exit 0:

```
{"version":1,"worktree":"/src/app/worktrees/feat/x","branch":"feat/x","main_checkout":"/src/app","main_workspace":"w3"}
```

| Field | Meaning |
| --- | --- |
| `version` | `1`. Changes only when a field changes. |
| `worktree` | The worktree's root folder; `null` outside one. |
| `branch` | The worktree's whole branch name; `null` outside one. |
| `main_checkout` | The main checkout's folder; `null` outside both a worktree and the main checkout. |
| `main_workspace` | The herdr workspace id open on the main checkout; `null` when herdr is not running, takes over half a second, or has none open. |

Every field is always present. Read one with `jq -r '.main_workspace // empty'`.

## `~/.whiska/owl.sock`

The running owl answers on a Unix socket, so a script can ask without starting Whiska: a
few milliseconds instead of a quarter of a second. Send one line, get one line back:

```
echo waiting | nc -U ~/.whiska/owl.sock | jq -r '.waiting[] | "\(.repo)  \(.branch)  \(.pointer)"'
```

| Request | Answer |
| --- | --- |
| `waiting` | `{"version":1,"waiting":[…]}`: everything waiting in every repo, oldest first, as the rows `whiska waiting --json` prints: `repo`, `main_checkout`, `branch`, `id` (`null` while still on the doorstep), `kind`, `status`, `pointer`, `age_seconds`, `pane`, `waits`, `held`. |
| `show <id> <main_checkout>` | `{"version":1,"question":{…}}`: `id`, `repo`, `main_checkout`, `branch`, `kind`, `status`, `pointer`, `text` (the whole message), `asked_at` (ISO 8601). Ids are numbered per repo, so the main checkout is needed; everything after the id is the path, spaces and all. |
| `jump` | `{"version":1,"whiskas":[…]}`: the rows `whiska jump --list --json` prints: `repo`, `main_checkout`, `waiting`, `oldest_wait_seconds` (`null` when nothing waits), `summary`, `main_session`. |
| `questions <main_checkout>` | `{"version":1,"questions":"…"}`: the text `whiska questions` prints in that repo. Only for a repo the owl has open. |
| `line [hint]` | The tab-bar line, as plain text. The hint is added at the end when something not held is waiting. |

A request it does not know gets `{"version":1,"error":"unknown request"}`. `show` and
`questions` can also answer `no such house`, `no such question` or `unreadable house`.
No answer at all means the owl is not running; `whiska waiting --json` reads the same
rows without it. Only your own user can open the socket.

## Environment variables

- **`WHISKA_HOME`** moves `~/.whiska`: the open-houses record, both sockets, `bin/`,
  `herdr-status.sh`, and the owl's wrapper and log.
- **`WHISKA_BIN`** and **`WHISKA_ESCRIPT`** point at the `whiska` binary and Erlang's
  `escript`, for the hook shim and the owl's wrapper; the one-word commands read
  `WHISKA_BIN` too. A path that is not executable is ignored. `whiska owl install` copies them into the owl's job, so
  run it again after changing either.
- **`HERDR_SOCKET_PATH`** is herdr's socket, `~/.config/herdr/herdr.sock` when unset.
  Also copied into the owl's job.
- **`WHISKA_HOOK_SOCKET`** points the shim at another hook socket. For tests and the
  doctor.

## Opening Whiska's links in your own viewer

`whiska show` links files. A spec, build plan, research document or report is a `.md`
file; a finished branch's diff is a `.diff` patch, `git diff <base>...<branch>` as git
prints it. A click opens each the way your terminal opens any file link, so you send each
file type to your own viewer where you choose every other file's:

- **Your terminal's open actions**, such as kitty's `open-actions.conf`:

  ```
  protocol file
  ext diff,patch
  action launch --type=tab your-diff-viewer ${FILE_PATH}
  ```

- **Your OS's default app for the type**: on macOS, Get Info on any `.diff` file, then
  Open With and Change All; on Linux, `xdg-mime default <app>.desktop text/x-patch`.

## More

- [The global install](internals.md#the-global-install), for a repo that cannot carry a
  committed `.claude/`.
- [Wiring the tab bar and the sidebar](internals.md#wiring-the-tab-bar-and-the-sidebar)
  into herdr's config.
- [What a session is told](internals.md#what-a-session-is-told-its-brief): its brief, and
  the `checks:` line `whiska land` reads.
- [What is enforced](internals.md#what-is-enforced), and what is not.
