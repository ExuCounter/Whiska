# What Whiska assumes about the world

An audit of everything Whiska relies on outside its own code, done 2026-10-04 against
`2f7619b` and brought up to date with main later the same day, herdr 0.8.2 and Claude Code 2.1.285 on macOS arm64. It changes nothing; it
says where each assumption lives, how it breaks, and what loosening it would cost.
Checked against main again on 2026-10-13: Whiska's own Claude Code statusline is gone, and
the board is drawn as a line per mouse in herdr's sidebar (ADR-0082). Brought up to date
again on 2026-10-13: each session's brief is on its Claude Code launch line, Whiska ships
no skills, and it registers three hooks (ADR-0088).

The Hex packages are out of scope. They were audited separately: eleven in the lock,
five declared (`ecto` and `exqlite` among them, since Whiska calls both directly), and
JSON from Elixir 1.19's own module.

- [The short answer](#the-short-answer)
- [Cheap ways to fail loudly](#cheap-ways-to-fail-loudly)
- [herdr](#herdr)
- [Claude Code](#claude-code)
- [macOS](#macos)
- [Everything else](#everything-else)
- [Drop, make optional, keep](#drop-make-optional-keep)
- [Order of work](#order-of-work)
- [Open questions](#open-questions)

## The short answer

- **Claude Code is the product.** Its hooks, transcript and screen are what Whiska
  does its work through. Nothing here can be dropped. The danger is that several of
  its changes would fail **silently**, and some of those can be made loud for an hour's
  work each.
- **herdr is load-bearing, and its shape has leaked.** The socket client is one narrow
  module, but herdr's words (`idle`, `done`, `working`, `"claude"`, its event names,
  `HERDR_PANE_ID`) are matched in the house, pickup, the sidebar, the doctor and the CLI,
  and `whiska spawn` and `whiska drop` create and remove worktrees through it.
  Swapping herdr out is about a week's work, and only worth it if someone without herdr
  will run Whiska. The doctor checks herdr is 0.9 or newer, which the sidebar needs;
  nothing checks Claude Code's version.
- **macOS is no longer required.** Done 2026-10-05: launchd is macOS's half, and a
  systemd user unit is Linux's (ADR-0040).
  The desktop notifier adds `notify-send`, and a missing `launchctl` or `systemctl` reads as
  "not loaded" rather than raising. `mix test` passes in a Linux container. `stat` and the
  paths already had fallbacks.
- **git, the shell and SQLite are fine.** git is used through exit codes and fixed
  `--format` output, so it is locale-safe. The shell is bash with no GNU-only flags
  except one `sort -V`. SQLite comes inside `exqlite`'s NIF, downloaded prebuilt for this
  platform from exqlite's GitHub releases at build time, against checksums the package
  pins. Where that download fails or no build matches, it is compiled from source, which
  needs a C compiler and `make`. Either way the escript must be built on the platform it
  runs on.

## Cheap ways to fail loudly

These are the highest-value findings. Each turns a silent failure into a visible one,
and none changes what Whiska does when things are working. Ordered by how bad the
silent version is.

1. **A prompt box Whiska cannot read is delivered into anyway, and only the doctor
   says so.** `Whiska.Delivery.Draft` returns `:unknown` when it finds a frame but no
   `❯` line it knows, and `Draft.hold/1` lets it through. Both the house's delivery and
   pickup (ADR-0067) go through it, so either can type into a draft.
   If Claude Code changes its prompt marker, every delivery can land inside a
   half-typed draft, which is exactly what ADR-0047 exists to stop. `whiska doctor`
   warns, but only when someone runs it. **Fix:** put a line in the sidebar, and
   `warn_once` to the log, when the read is `:unknown`, next to `Draft.hold/1` so it covers
   pickup too. About an hour.
2. **Whiska's shim fails open with exit 0, so its warning is probably never seen.**
   When the binary or runtime is missing, the shim prints to stderr and exits 0
   (`install.ex`, `@shim_fail_open`, `@shim_exec`). Claude Code's hook docs say it
   shows stderr for a non-zero, non-2 exit, and only in verbose mode for exit 0. So
   "fail open, loudly" is quiet in practice: a hold stops nothing and, worse,
   the `Stop` hook leaves nothing on the doorstep, so a mouse's question vanishes.
   **Fix:** exit 1 instead of 0 on those two paths. Exit 1 still allows the call (only
   2 blocks) and shows the message. **Done:** it exits 1 inside a worktree of a repo
   Whiska is set up in, and stays quiet elsewhere. The `Stop` path also says the turn's
   message was not delivered. Merged to main as `755718a`, tested
   against Claude Code 2.1.285.
3. **No version check against herdr or Claude Code.** Every comment that says "checked
   against herdr 0.8.2" is a promise nothing enforces. herdr answers
   `{"method":"ping"}` with `{"version":"0.8.2","protocol":20,...}`, and
   `claude --version` prints `2.1.285 (Claude Code)`. **Fix:** record the versions the
   contracts were last checked against, and have the doctor warn when either is newer:
   "herdr 0.9.0 is newer than 0.8.2, which Whiska was last checked against". A warning,
   never a refusal. About two hours. Comparing herdr's `protocol` number is the
   sharper test, since it moves only when the wire changes. **Half done:** the doctor
   asks herdr for its version and warns below 0.9. It does not warn on a newer version,
   and Claude Code's is never read.
4. **An agent status Whiska does not know reads as "mid-turn" forever.**
   `main_session_free?/1` holds on any status that is not `idle`, `done` or `unknown`,
   and the sidebar says `⏳ gated: main is mid-turn`. If herdr renames `idle`,
   questions are held with a reason that sends the person looking in the wrong place.
   **Fix:** a separate hold reason for a status outside herdr's five, worded as
   "herdr said `ready`, which Whiska does not know". About an hour.
5. **A new or renamed editing tool passes a hold and sniff without a sound.** The hook
   matcher is `Write|Edit|MultiEdit|NotebookEdit|Bash` (`install.ex`), and a sniff mouse's
   deny list names `Edit`, `Write` and `NotebookEdit` (`deny_list.ex`). A tool outside
   those is allowed, and nothing is logged. MCP tools that write files are
   already in this hole today. **Fix:** the doctor reads the tool names in recent
   transcripts and warns about any it has never classified. Half a day. A narrower
   option is to log tool names the hook sees but has no rule for, but the matcher means
   it never sees the new ones.
6. **`CLAUDE_CONFIG_DIR` is ignored.** Whiska hard-codes `~/.claude` for transcripts
   (`transcript.ex`, `project_dir/2`), the global install and the doctor. Someone who
   sets it gets an empty "what is it doing" column and a global install Claude Code
   never reads. **Fix:** honour the variable, or have the doctor warn when it is set.
   Under an hour either way.
7. ~~**On Linux the owl crashes on launch instead of saying why.**~~ Done 2026-10-05: a
   service manager whose program is missing answers "not loaded". See [macOS](#macos).

The rest already fail loudly enough: an unknown herdr method comes back as an error and
holds delivery with a logged reason; a renamed herdr event is caught by the backstop,
which the doctor reports; a missing `last_assistant_message` delivers an empty
question, which the person notices.

## herdr

**What it gives Whiska that nothing else does:** whether each Claude Code session is
working or idle, a way to type into a pane, the visible screen, and pane lifecycle
events. Everything else herdr does for Whiska could come from somewhere else.

**Where the boundary is.** `Whiska.Herdr` is a behaviour with 16 callbacks, and
`Whiska.Herdr.Socket` is the only file that speaks herdr's wire (ADR-0031). It is a
tolerant reader: unknown fields are dropped, a missing `agent_status` becomes
`"unknown"`, and a reply that does not match is `{:error, {:unexpected_reply, _}}`.
That part is well built.

**Where it leaks.** The house deliberately keeps herdr's names verbatim
(`owl/house.ex`, the comment above `event_name/1`), so herdr's vocabulary is matched
outside the boundary:

| What | Where it is matched | If herdr changes it |
| --- | --- | --- |
| Agent statuses `idle` `done` `working` `blocked` `unknown` | `owl/house.ex`, `pickup.ex`, `watch.ex`, `doctor.ex` | Renamed `idle`: mice collected a minute late by the backstop (doctor warns); delivery held as "mid-turn" (misleading, see fix 4) |
| A pane stays `working` while a subagent is out ("Waiting for N background agents"), and reads `idle` while only other background work runs (checked 2026-10-14) | `watch.ex` (ADR-0082) | A pane kept working for a background command: `✖ stuck` after five minutes while it runs. Visible, misleading |
| Agent name `"claude"` | house, pickup, cli, doctor (6 places) | Held with "not running Claude" in the log and the doctor. Loud |
| Event names `pane_closed` `pane_exited` `pane_agent_detected` `workspace_closed` `pane.agent_status_changed` | `owl/house.ex` | Unknown events are dropped. The backstop and the two-second sweep cover it, a minute late. Doctor warns |
| `HERDR_PANE_ID`, `HERDR_SOCKET_PATH`, `HERDR_CONFIG_PATH`, `~/.config/herdr/herdr.sock` | `session.ex`, `cli.ex`, `herdr.ex`, the owl's launchd or systemd job | Main session not recognised: the person's own turns would be filed as mouse messages. Silent |
| Methods `ping` `pane.list` `pane.get` `pane.read` `pane.process_info` `agent.start` `agent.prompt` `pane.send_text` `pane.focus` `workspace.list` `workspace.move_block` `workspace.report_metadata` `worktree.create` `worktree.list` `worktree.open` `worktree.remove` `events.subscribe` | `herdr/socket.ex` only | herdr returns an error; delivery holds with a logged reason, and `spawn`, `send` or `drop` says what failed. Loud |
| `agent.start` with `kind = "claude"` and `args` waits until Claude is ready, then answers its `argv` | `herdr/socket.ex`, `spawn.ex` | A spawned mouse starts without its brief or shape flags, or `spawn` times out after 15 s and says where the worktree is. Loud |
| `pane.process_info` lists the pane's foreground processes with their `argv` | `brief.ex`, `doctor.ex`, `whiska start`, `restart.ex` | Renamed: the doctor's `main brief` line says "not checked". `argv` dropped: the doctor and `whiska start` say the main session was started without its brief when it was. Visible, misleading. `restart.ex` acts only on a process named `claude` with a non-empty `argv` lacking the flags, so a renamed or argument-less list leaves every mouse unrestarted: silent |
| Wire: one JSON line per request, connection closed after; subscriptions stay open | `herdr/socket.ex` only | Every call errors. Loud |
| `[ui] tab_bar_right` entry with `type = "command"`, `interval_seconds`, `timeout_seconds` | `install.ex` snippet, `doctor.ex` check | Owl's line disappears from the tab bar. Doctor checks the entry is there, not that herdr still draws it |
| `[ui.toast] delivery` is one switch over herdr's own agent toasts, a mouse's included, and every `notification.show`, with no per-pane filter, and answers `shown: true` with it off (checked 2026-10-15, herdr 0.9.3) | nothing: hoots never go through herdr (ADR-0062) | A per-pane filter would let hoots go back through it. Fine |
| `[ui.sidebar.spaces]` rows with `rules`, and `workspace.report_metadata`, both herdr 0.9 | `sidebar.ex`, `owl/house.ex`, `doctor.ex` | Each mouse's sidebar line disappears. Doctor checks the version and the rows, not that herdr still draws them |

**Version check.** The doctor warns below herdr 0.9. `ping` also returns a protocol
number, so warning on a newer herdr is cheap (fix 3).

**Swapping in another multiplexer.** The callbacks map onto tmux reasonably well:
`capture-pane` reads the screen, `send-keys` types, `list-panes -F` lists, and a
desktop notifier already exists. What tmux has no equivalent for is herdr's agent
status. Whiska would have to work that out itself, most likely from Claude Code's own
hooks (`UserPromptSubmit` for working, `Stop` and `Notification` for idle), which
trades a herdr dependency for more Claude Code hook surface. Add the leaked vocabulary,
herdr's worktree and agent-start calls, the tab bar and `HERDR_PANE_ID`, and it is about a week. ADR-0020 (mice
stay herdr panes) would have to be revisited first. Not worth doing unless someone
without herdr wants to run Whiska.

The first step is useful on its own and is now planned work (item 11 in
[Order of work](#order-of-work)): translate statuses to atoms and `agent == "claude"`
to a boolean inside `Whiska.Herdr.Socket`, so the house stops matching herdr's
strings. That reverses the "herdr's own name, verbatim" choice in the house, so it
comes with an ADR.

## Claude Code

Every row is someone else's UI or file format, and can change in any release.

| What | Where | If it changes |
| --- | --- | --- |
| `PreToolUse`, `Stop` and `UserPromptSubmit` hook names, `matcher`, `{"type": "command"}` layout in `settings.json` | `install.ex`, `doctor.ex` | Hooks stop firing. Doctor reads the file and probes the shim, so it would see a missing entry but not a renamed event. Half-loud |
| `$CLAUDE_PROJECT_DIR` in the hook command | `install.ex` | Shim path fails, Claude Code shows a hook error. Loud |
| Payload: `cwd`, `transcript_path` | `hook/pre_tool_use.ex`, `session.ex` | A renamed key means no start directory, so the call is allowed and a hold stops nothing. **Silent** |
| Payload: `last_assistant_message` on `Stop` | `hook/stop.ex` | Empty question delivered. Loud |
| Deny output: `hookSpecificOutput.permissionDecision = "deny"` | `hook/pre_tool_use.ex` | Denials ignored, every call allowed. **Silent**. The doctor's probe runs with an outside-worktree payload, so it never sees a deny |
| Tool names `Write` `Edit` `MultiEdit` `NotebookEdit` `Bash` | matcher in `install.ex`, sniff's deny list in `deny_list.ex` | New or renamed editing tool passes a hold and a sniff mouse's deny list. **Silent** (fix 5) |
| `--dangerously-skip-permissions`, `--settings <file>`, and `permissions.deny` rules as `Bash(<command> *)` and bare tool names, holding in bypass mode | `deny_list.ex` (ADR-0090) | A renamed flag stops the launch: loud. A changed rule syntax lets a mouse run the person's commands, or a sniff mouse edit. **Silent** |
| Global and project hook arrays merge | the global shim's stand-down | Double denials and double doorstep entries. Visible |
| `settings.json` read once at startup | doctor's session-wiring check | Doctor gives a wrong "restart" hint. Cosmetic |
| Transcript at `~/.claude/projects/<slug>/<session>.jsonl`, slug = every non-alphanumeric to `-` | `transcript.ex`, `watch/transcript.ex` | No last action on a stuck mouse's sidebar line. Benign. `CLAUDE_CONFIG_DIR` is ignored (fix 6) |
| Transcript first entry carries `cwd` | `session.ex` (ADR-0053) | Falls back to the payload's `cwd`, which follows `cd`. A main session that stepped into a worktree could be read as that mouse. Rare, silent |
| Transcript background-work shapes: `Agent` tool, `agentId:` text, `toolUseResult` `backgroundTaskId` (`Bash`), `resumedAgentId` (`SendMessage`), `taskId`/`persistent` (`Monitor`, `Workflow`), `task_id` (`TaskStop`), `origin.kind/handback/from`, `<task-notification>` with its `<status>`, interim `<note>`, `<result>`/`<event>` order and `[Monitor expired` event, `<agent-message>`, `[Subagent hand-back]`, `isSidechain`, `attachment`, `isApiErrorMessage` | `transcript.ex` (ADR-0052) | Launch missed: a progress note delivered early. Hand-back missed: the mouse is held silent up to 30 minutes, then its sidebar line says stuck. Bounded, visible |
| Transcript file birth time as session start | `transcript.ex` | Doctor reports "unchecked". Graceful |
| Prompt box: column-0 `─` rules, `❯` marker followed by a non-breaking space, then padding | `delivery/draft.ex` (ADR-0047) | Rules change: held as "box not on screen" (loud, misleading). Marker changes: delivered into a draft (**silent**, fix 1) |
| Claude Code draws its suggested next prompt and placeholder as faint text (SGR 2), read with herdr's `--format ansi` | `delivery/draft.ex` | Suggestions drawn in another style read as typing, so questions are held as "your prompt box isn't empty". Misleading, and silent until someone asks why nothing arrives |
| Alternate screen | the main session's brief tells the model not to read a pane | Nothing in code depends on it |
| U+2063 draws nothing in the terminal | `question/marker.ex` | Three odd glyphs appear in the pane. Visible, harmless. The marker is read from the payload, not the screen |
| Skills at `.claude/skills/<name>/SKILL.md` | `install.ex`, to find and delete the ones an older Whiska wrote | An older skill left where Claude Code still lists it. Visible: the doctor names it |
| `--append-system-prompt-file <path>` adds the file to the system prompt, in an interactive session | `brief.ex`, `whiska start`, `spawn.ex`, `whiska shape` (ADR-0088) | Removed: `claude` refuses the flag and nothing starts. Loud. Ignored: a session runs without its brief. Silent, but ADR-0009 makes a missing marker deliver, so the person notices |
| The system prompt is kept across `/clear`, a resume and compaction: `claude --help` documents `--system-prompt-snapshot`, on by default, recording it on the first request and resending it as-is until compaction renders it again | the briefs carry no "you were just compacted" step beyond rereading the `.whiska-*` files | A session loses its brief part way through. Silent |
| `UserPromptSubmit` output `additionalContext` reaches the model | `hook/user_prompt_submit.ex` (ADR-0080) | An answer is stamped taken but never reaches the mouse. **Silent** |
| `claude` on `PATH`, `--model`, `--effort` and `--autocompact` flags | `whiska start`, `whiska shape`, `spawn.ex` | Command fails in the pane, or `spawn` reports herdr's error. Loud |

**The pattern.** Anything the model reads or writes fails visibly, because the person
reads the output. What fails silently is what the hook **decides**: a payload key, a
tool name or the deny format changing all turn enforcement off without a word. Those
are worth a contract test: a doctor probe that runs the shim with an inside-worktree
`Edit` aimed at the main checkout and checks the JSON that comes back. The probe has
to run in a throwaway repo under tmp, because the hook mints a marker and records a
mouse, and the doctor never writes (ADR-0038). It still
cannot prove Claude Code honours the deny; only a real session can, which is the
version warning's job.

## macOS

| What | Where | Portable today? | To make it portable |
| --- | --- | --- | --- |
| launchd: plist in `~/Library/LaunchAgents`, `launchctl bootstrap/bootout/kickstart/kill/print`, `gui/<uid>` domain, regex over `launchctl print` text | `launch_agent.ex` | macOS only, by design. On Linux `systemd_unit.ex` does the same job through `systemctl --user`, and a missing program of either kind is "not loaded" | Done |
| `launchctl print` text format (`pid = N`, `last exit code = N`) | `launch_agent.ex` | macOS-only, and undocumented by Apple | A changed format reads as "loaded, not running". Doctor would mislead. Low risk |
| `terminal-notifier` (`-title -message -sound -execute -activate`, each value read as a property list, so `(`, `{` or `<` first never returns), then `osascript`, then `notify-send` | `desktop/notifier.ex` | Yes. None is `{:error, :no_notifier}`, which the doctor reports; without `terminal-notifier` a hoot has no click, and the doctor says so | Done |
| Homebrew paths `/opt/homebrew/bin`, `/usr/local/bin` | shim, doctor | Last-resort lookups for `escript` after `PATH`. Harmless elsewhere | Nothing needed |
| `stat -f %B` / `-f %m` | `transcript.ex` | Yes: it tries BSD then GNU, and checks the answer | Done |
| `sort -V` | shim, asdf lookup | GNU and recent macOS. Old macOS fails the step and falls through | Nothing needed |
| `pgrep -f`, `ps -o etime=`, `id -u`, `kill -9` | `owl.ex`, `launch_agent.ex`, notifier | Yes | Done |
| Escript with the SQLite NIF baked in | `bundled_nif.ex` | The binary carries one platform's `sqlite3_nif.so`, fetched or compiled when the escript is built, so fine. Cannot ship one binary for every platform | Per-platform builds, or ADR-0033's native hook. Only matters for distribution |

## Everything else

- **git.** Uses `worktree` (and `worktree remove`, git 2.17+), `branch --format`
  (2.13+), `symbolic-ref`, `rev-parse`, `merge-base --is-ancestor`, `rev-list
  --first-parent`, `status --porcelain`. Every answer is an exit code or a fixed
  format, never a translated message, so locale does not matter. Assumes a
  mouse's base is the branch the main checkout was on at spawn (recorded by `whiska
  shape`); with none recorded, `origin/HEAD`, else exactly one of `main` or `master`,
  and answers "do nothing" otherwise. Layout leans on git's `.git` file pointing into
  `.git/worktrees/`, unchanged for a decade. `mix adr.claim` hard-codes `main`, which
  only matters for this repo. Nothing to loosen.
- **The `worktrees/<branch>` layout** is Whiska's own convention (ADR-0030), not an
  outside one. `whiska spawn` asks herdr's `worktree.create` for exactly that path.
- **`gh` and `glab`.** `whiska pr` opens a merge request with `gh`, or `glab` when the
  remote's URL names GitLab, signed in by the person. A missing or signed-out tool is
  said, and nothing stands in for it (ADR-0085). `whiska land` and `whiska pr` also use
  git's `cherry-pick` and `push`.
- **Shell.** bash for the shim, the one-word commands, the owl wrapper and the tab-bar
  script; `grep -q`, `tail`, `ls`, `cat`, all POSIX, plus `nc -U`. No script needs
  `jq`. The shim sets `LC_ALL=C` to count the payload's bytes, the one place locale
  could have mattered.
- **Erlang runtime.** The escript needs `escript` at run time. The shim finds it on
  `PATH`, through `asdf`, under `~/.asdf`, or at the Homebrew paths. It does not look
  in `mise`'s shims or a Nix profile. A hook with neither on `PATH` fails open, which
  since fix 2 at least says so. Adding `~/.local/share/mise/shims`: five minutes.
- **SQLite.** `exqlite` brings its own SQLite, prebuilt or compiled, so the system's
  version does not matter. WAL mode and a 5-second busy timeout are set in `storage.ex`. WAL needs a
  local filesystem; a home directory on NFS would break locking. Unlikely here.
- **Desktop.** Nothing assumes a GUI apart from the hoot, which tries `terminal-notifier`, `osascript` and `notify-send` in turn.

## Drop, make optional, keep

Ranked by what a person would gain. **Other people will run Whiska** (decided
2026-10-04), so the
Linux and herdr-decoupling items below are real work, not hypothetical.

1. **Make the silent failures loud** (fixes 1 to 7; 2 and 7 are done, 3 is half done). Gain: the next
   herdr or Claude Code release that breaks something is noticed the same day, not
   after a lost question. Cost: about two days in total.
2. ~~**Unblock Linux**~~ Done 2026-10-05: fix 7, a systemd unit and `notify-send`. Whiska
   runs on a Linux box; in a container without systemd the owl runs in a pane.
3. ~~**Drop `jq` from the skills** by giving them `whiska` subcommands to call.~~ Done:
   `jq` is gone from the skills and the repo's push hook. Gain:
   one less tool for a new user to install, and the herdr CLI calls move into code that
   has tests. Cost: half a day.
4. **Keep herdr, but take its words out of the core.** Removing herdr is a week and
   needs ADR-0020 revisited. Moving its statuses, agent name and event names behind
   `Whiska.Herdr.Socket` is the first step towards a second multiplexer, and is planned
   work.
5. **Keep Claude Code.** It is what Whiska coordinates. Supporting another agent would
   mean new hooks, a new transcript reader, a new prompt-box reader and a new marker
   contract: a rewrite, not a loosening.
6. **Keep git, bash, SQLite and the Erlang runtime as they are.** They do not move,
   and abstracting them would cost more than it saves.

**Where "more general" is still not worth it.** git, bash, SQLite and Claude Code
itself. And whatever the platform, the biggest exposure is **drift**: herdr and Claude
Code change under Whiska on the same machine, and today little notices. That is why
rank 1 is first.

## Order of work

Decided 2026-10-04: other people will run Whiska, so the loud-failure fixes and Linux
support go ahead, and taking herdr's words out of the core is planned work, not
dropped. Proposed order, cheapest unblockers first. Struck-through rows are done, and so
is the shim's exit code (fix 2), merged as `755718a`.

| # | Piece | Cost | Why here |
| --- | --- | --- | --- |
| 1 | ~~Rescue a missing `launchctl` as "not loaded" (fix 7)~~ Done | 30 min with a test | Owl and doctor start on Linux at all |
| 2 | Version check: herdr `ping`, `claude --version`, doctor warns when newer than last checked (fix 3). Half done: the doctor warns below herdr 0.9 | 2 h | Other people run other versions. Every later report starts with "which versions?" |
| 3 | Unreadable prompt box goes in the sidebar and the log (fix 1) | 1 h | Worst silent failure: typing into a draft |
| 4 | Own hold reason for an agent status Whiska does not know (fix 4) | 1 h | Stops "mid-turn" sending people the wrong way |
| 5 | Honour `CLAUDE_CONFIG_DIR` (fix 6) | 1 h | Cheap; other people set it |
| 6 | Doctor probes a real deny: inside-worktree `Edit` at the main checkout, check the JSON back. Run it in a throwaway repo under tmp: the hook mints a marker and records a mouse, and the doctor never writes (ADR-0038) | 2 h | Covers the deny format and payload keys |
| 7 | Doctor warns about tool names in transcripts it has never classified (fix 5) | half a day | Covers new editing tools and MCP writers |
| 8 | ~~Run `mix test` in a Linux container, fix what is macOS-only~~ Done: six failures, four of them tests that assumed macOS or a herdr pane, one a real notifier race | 1 h to learn, unknown to fix | Turns the Linux cost from a guess into a number |
| 9 | ~~systemd user unit behind the launchd runner, `notify-send` fallback, README's "Requires macOS" rewritten~~ Done. `mise` shims in the runtime lookup are still open | about 1.5 days | Linux supported, not just not crashing |
| 10 | ~~Skills call `whiska` subcommands instead of `herdr … \| jq`~~ Done | half a day | One less thing for a new user to install, and the herdr CLI moves into tested code |
| 11 | herdr's statuses, agent name and event names translated inside `Whiska.Herdr.Socket`; the house, pickup, sidebar, doctor and CLI match Whiska's own words | 1–2 days, mostly tests through the Mox fake | Prerequisite for a second multiplexer. Reverses the "herdr's own name, verbatim" choice, so it comes with an ADR |

Items 2–7 come to about two days and need no new design. Items 8 and 9 are done; herdr
runs on Linux (herdr.dev lists macOS, Linux and Windows).

## Open questions

These need the person, not a guess.

1. ~~Will anyone but you run Whiska?~~ Yes, decided 2026-10-04.
2. **Should a version newer than the checked one only warn, or also add a line to the
   sidebar?** The doctor alone is only as loud as how often it is run.
3. ~~Is changing the shim's fail-open exit from 0 to 1 acceptable?~~ Yes, done in
   `755718a`.
4. ~~Should the house stop matching herdr's strings?~~ Yes, as planned later work
   (item 11), decided 2026-10-04.
5. ~~Does herdr run on Linux?~~ Yes, per herdr.dev, checked 2026-10-04.
