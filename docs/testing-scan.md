# Testing scan: what is still unprotected

A `$wio scan` of the whole repo at `9457196`, run 2026-10-03. This scan is read-only,
so it writes no tests. It follows a doctor pass from the same day, which found the
suite is not bloated (12,631 lines of lib, 17,892 of test, 1434 tests) and that it runs
serially. The question here is the opposite one: given all that coverage, which
behaviour is still unprotected and would hurt if it broke?

## Scope And Evidence

- **Target:** all of `lib/whiska`. Six read-only scouts went deeper into six areas:
  - the delivery and pickup gates
  - the doorstep
  - the owl
  - SQLite storage
  - `whiska init`
  - everything else: hooks, rules, shell parsing, cleanup and transcript
- **Code read:**
  - delivery and pickup: `delivery/{draft,text,hoot}.ex`, `pickup.ex`, `owl.ex`, `owl/house.ex`, `herdr/socket.ex`
  - doorstep and questions: `doorstep.ex`, `question/marker.ex`, `questions.ex`
  - storage: `storage.ex`, `repo.ex`, `migrations/v001–v006`
  - init: `install.ex`, `claude_md.ex`, `cli.ex` (init and owl), `launch_agent.ex`
  - hooks and rules: `hook/{pre_tool_use,stop}.ex`, `rule/main_checkout.ex`, `shell.ex`
  - the rest: `isolated.ex`, `transcript.ex`, `cleanup.ex`, `git.ex`, `watch/snapshot.ex`
- **Tests read:** the matching files under `test/whiska/`, plus `test/support/screens`
  and `test/support/{home_guard,real_home}.ex`.
- **Churn in the last 3 weeks:** 218 commits, 57 of them `fix:`. The biggest bug
  clusters by `fix:` count are:

  | File | Commits | `fix:` |
  | --- | --- | --- |
  | `transcript.ex` | 8 | 6 |
  | `git.ex` | 7 | 3 |
  | `cleanup.ex` | 6 | 3 |
  | `pre_tool_use.ex` | 5 | 3 |
  | `stop.ex` | 4 | 3 |
- **Commands run:** read-only probes only.
  - `elixir -r lib/whiska/shell.ex` was run against `Whiska.Shell.paths/1`.
  - The typed-line regex was run in a scratch `elixir -e`.
  - `mix test` was not run. This worktree has no fetched deps, and the scan writes no
    code.
- **Confirmed vs inferred:** each candidate below says how far it was checked:
  - **run**: a probe reproduced it.
  - **read**: I traced it in the code myself.
  - **inferred**: it needs a live capture or a design answer first.

## Ranked Candidates

1. **A mouse can write into the main checkout through Bash.**
   - **Impact:** this breaks the ADR-0013 boundary that keeps mice out of the main
     checkout.
   - **Risk:** `MainCheckout.decide("Bash")` expands every path-like token against the
     worktree (`rule/main_checkout.ex:97`). A token the shell parser does not clean ends
     up inside the worktree, and `judge` allows it. Confirmed by **run**:
     `Shell.paths/1` returns these tokens raw:
     - `echo x 2>/main/f` gives `["2>/main/f"]`
     - `dd of=/main/f` gives `["of=/main/f"]`
     - `rm $HOME/…/main/f` gives `["$HOME/…/main/f"]`

     All three resolve under the worktree, so all three are allowed.
   - **Second, related way in:** `resolve/2` ignores the hook payload's `cwd`. After
     `cd <main>`, the next call `rm CONTEXT.md` is checked against the worktree and
     allowed. This one is **read**. ADR-0053 records that the shell does wander out of
     the worktree.
   - **Nearest test:** `rule/main_checkout_test.exs:161`, which covers only `> path`.
   - **Assertion that would fail:**
     `{:deny, _} = MainCheckout.decide("Bash", %{"command" => "echo x 2>#{main}/lib/x.ex"}, layout)`.
     Add one case each for `of=`, `$HOME` and a `cwd` of main.
   - **References:** risk-based-testing, test-level-selection, security-testing.
   - **Strategy:** a unit table in `main_checkout_test.exs`, plus one hook-level case
     for `cwd`.
   - **Cost:** small.

2. **Control characters reach the line the owl types into the person's session.**
   - **Impact:** a stray `\r` submits half a line in the person's live session.
     `\e[201~` closes a bracketed paste, so the rest of the line is read as keystrokes.
   - **Risk:** `Text.compose/4` only replaces `~r/\s*\n\s*/` (`delivery/text.ex:48`).
     `Marker.pointer/1` only splits on `\n`. The branch name comes from the doorstep
     entry unchanged (`owl/house.ex:840`, `:1017`). Confirmed by **run**: the regex
     leaves `"hi\rthere\e[201~x"` untouched. Hoot titles (`delivery/hoot.ex:61`) have
     the same gap.
   - **Nearest test:** `delivery/text_test.exs:72`, which only checks for `\n`.
   - **Assertion that would fail:** compose with text and a branch containing `\r`,
     `\e[201~`, `\x03` and `\t`, then
     `refute String.match?(line, ~r/[\x00-\x1f\x7f]/)`.
   - **References:** property-based-testing, security-testing.
   - **Strategy:** unit tests, plus a StreamData property over random control bytes.
   - **Cost:** small.

3. **Delivery and pickup must reach the same answer on the same screen.**
   - **Impact:** this is the class of bug that shipped today (`9457196`): each gate was
     green alone and wrong together.
   - **Risk:** both gates now share one reader, `Draft.read/1`. Each gate still maps
     the result to hold or type in its own hand-written block:
     - delivery: `owl/house.ex:1002-1013`
     - pickup: `pickup.ex:279-293`
     - doctor reads the screen a third time: `doctor.ex:999`

     Today the three blocks agree (**read**). Nothing keeps them agreeing.
   - **Nearest tests:** the pickup tests use 3 of the 7 saved screens, and never try
     `:unknown` or a deliberate read error.
   - **Assertion that would fail:** for every file in `test/support/screens`, plus a
     read error, delivery's hold reason equals pickup's `{:left, reason}`, and a go
     equals `:picked_up`. A cheaper alternative is to move the decision into one
     function such as `Draft.hold?/1` and test that function once.
   - **Follow-on (inferred):** in Claude Code's bash mode (`!`) the box marker may not
     be `❯`. If so, the reader returns `:unknown`, both gates type, and the line lands
     in the person's half-written shell command. Capture a real `!` screen first. Once
     captured, it joins this test for free.
   - **References:** test-oracles-and-assertions, test-level-selection.
   - **Strategy:** a table test over the saved screens.
   - **Cost:** small.

4. **Re-running `init` on a CLAUDE.md with one end marker deleted by hand duplicates
   parts, and the run after that deletes the person's text.**
   - **Impact:** silent data loss in `~/.claude/CLAUDE.md`, which is usually a symlink
     into a dotfiles checkout. A `keep` part the person claimed can be lost too.
   - **Risk:** this is **read**, traced through `claude_md.ex`:
     1. When a part's start marker has no matching end, `segments/1` returns the whole
        block as `{:other, inside}` (`:422-436`). So `seen` is empty, and `rebuild`
        appends all six parts again.
     2. On the next run, `close/3` pairs the orphaned start marker with the newly
        appended end marker. It replaces everything between them with one fresh body.
     3. This breaks the comment at `:418-420`, which says a half-written marker is
        copied through unchanged.

     Deleting the outer `<!-- whiska:end -->` has the same shape and writes a second
     outer block (`split_outer`, `:369-376`).
   - **Nearest tests:** `claude_md_test.exs:456` (both markers missing) and `:521`
     (well-formed input only).
   - **Assertions that would fail:**
     - after one merge, each start marker appears exactly once
     - `merge(merge(x)) == merge(x)`
     - a `keep` part placed after the broken marker survives two merges
   - **References:** test-level-selection, risk-based-testing.
   - **Strategy:** unit tests on `ClaudeMd.merge/2`.
   - **Cost:** small.

5. **A crash loop in one house closes every house.**
   - **Impact:** questions from every repo stop arriving, while `pgrep` still sees an
     owl, so the statusline keeps saying "watching".
   - **Risk:** houses run under one `DynamicSupervisor`, inside a `rest_for_one`
     supervisor (`owl.ex:43-48`). Both use the default limit of 3 restarts in 5 s
     (**read**). A house whose `init` keeps returning `{:stop, …}`
     (`owl/house.ex:275`, `:382`) uses that budget up. The `DynamicSupervisor` then
     restarts empty, and nothing reopens the remembered houses.
   - **Nearest test:** `owl_test.exs:92`, which kills a house once.
   - **Assertion that would fail:** open houses a and b, then kill a 4 times. Assert
     `{:ok, _} = Owl.house(b)` and that both houses are still open.
   - **References:** resilience-testing-and-fault-injection.
   - **Strategy:** integration in `owl_test.exs`.
   - **Cost:** small.

6. **Two processes opening the shared database at once.**
   - **Impact:** a failure can leave a sniff mouse's edit running as build without a
     word. A house can also fail to start.
   - **Risk:** `Storage.open` runs `Ecto.Migrator.run(…, all: true)` on every open
     (`storage.ex:114`). Callers include the owl's house start and the PreToolUse hook
     in every worktree. ecto_sqlite3's `lock_for_migrations` is believed to be a no-op.
     This is **inferred**: deps are outside the worktree and the hook blocked reading
     them. If it is a no-op, two openers after a binary upgrade both see the same
     migration as pending, and one raises "duplicate column". A related case:
     `busy_timeout: 5_000` equals the `Isolated` deadline of 5 s, so a held lock gets
     the hook killed rather than given an error.
   - **Nearest test:** none. No test exercises concurrency, an older schema with real
     rows, or a locked database.
   - **Assertion that would fail:** run `Storage.open(main, name: nil)` from 4 tasks at
     once against a fresh database and one left at v5. All 4 return `{:ok, _}`, and
     the schema version is 6.
   - **References:** test-level-selection (needs real SQLite, no mocks).
   - **Strategy:** integration on a temp file, repeated a few times.
   - **Cost:** medium.

7. **A line typed but not recorded as sent gets typed again.**
   - **Impact:** the person sees the same question twice.
   - **Risk:** there are two ways in:
     - `send_question` types first and records after, with
       `{:ok, _} = Storage.mark_sent/1` (`owl/house.ex:1021-1023`, **read**). A failed
       record crashes the house with the question still open. Failure causes include a
       busy database, or the question being closed in between.
     - `Socket.prompt` returns `{:error, :timeout}` after 5 s even when herdr has
       already accepted the line. Delivery then retries, and pickup re-nudges.

     Pickup stamps first and types after, on purpose (`pickup.ex:299-306`). Delivery
     does not.
   - **Nearest tests:** `delivery_test.exs:333` and `:831`, which use a clean
     `{:error, _}` only.
   - **Assertion:** a fake herdr accepts the line, then the record fails or the call
     times out. `prompt` is called exactly once across two triggers and a restart.
   - **References:** resilience-testing-and-fault-injection.
   - **Strategy:** house integration with the existing fake herdr.
   - **Cost:** medium. This needs a design call first (see Open Questions).

8. **Two foreground owls are not refused.**
   - **Impact:** both owls deliver for the same checkout, so lines are typed twice.
     Both also write the board through the same fixed `.tmp` name
     (`watch/snapshot.ex:69`).
   - **Risk:** `not_supervised` (`cli.ex:870-885`) refuses only when launchd's owl is
     running. `owl install` checks `Owl.pids()`, and `start_owl` does not.
   - **Nearest test:** `cli_owl_test.exs:139`, which covers launchd only.
   - **Assertion:** with another owl's pid present, `start_owl` returns `{:error, _}`.
   - **Strategy:** a CLI unit test, plus an injectable pid lookup (`OpenHouses.open/2`
     already has one).
   - **Cost:** small.

9. **An unreadable doorstep entry blocks pickup, and nothing tells the person.**
   - **Impact:** the person gets no warning. Pickup stays refused until someone finds
     the file.
   - **Risk:** `Doorstep.waiting/1` skips a file it cannot parse, but `count_waiting/1`
     counts it (`doorstep.ex:76-81`). Pickup then refuses everything
     (`pickup.ex:323`), while `questions` and `doctor` show nothing. Invalid UTF-8, a
     lone surrogate, or a torn write from anything other than `leave/2` all trigger it.
   - **Nearest tests:** `doorstep_test.exs:82` and `pickup_test.exs:229` check the skip
     and the refusal, not that anyone is told.
   - **Assertion:** when `count_waiting > length(waiting)`, doctor or the questions
     listing names the bad entry.
   - **Cost:** small.

10. **A finished foreground subagent may hold back a mouse's final message for up to 30
    minutes.**
    - **Risk:** `@launched ~r/^agentId: …/m` (`transcript.ex:82`) is matched against
      every Agent tool result. If a synchronous Agent result also carries an `agentId:`
      line, the Stop hook reads it as "subagent still out" and leaves nothing on the
      doorstep (`hook/stop.ex:76`). This is **inferred**: it needs a real transcript
      sample.
    - **Why it ranks here:** `transcript.ex` is the biggest bug cluster in the repo.
    - **Nearest test:** `transcript_test.exs:14`, which has the async fixture only.
    - **Cost:** small, once a real sample exists.

11. **A dangling symlink during `init --global` leaves a half install, and the error
    names the wrong file.**
    - **Risk:** if `~/.claude/CLAUDE.md` points into a moved dotfiles checkout, the
      write fails. The catch-all then reports `settings.json`, even though skills were
      already written (`cli.ex:308-337`, `:650-661`).
    - **Nearest test:** `cli_init_global_symlink_test.exs`, which uses live targets
      only.
    - **Cost:** small to medium.

**Lower and parked:** these need a product or ADR call before a test can say what is
right.

- A doorstep entry that claims another mouse's `mouse_id`. It rewrites that mouse's
  path and marks its questions superseded (`owl/house.ex:833-851`,
  `storage.ex:139`, `:702`).
- Cleanup deleting gitignored files, because `git status --porcelain` hides them
  (`git.ex:164`).
- An older binary opening a newer database. This works today only because every
  migration adds nullable columns. A static check is cheaper than a test.
- Delivery typing into a pane id that herdr reused after the main pane closed. It is
  not confirmed that herdr reuses ids.
- `LaunchAgent.user_home/0` falling back to the real HOME in tests before
  `HomeGuard` notices. A cheaper fix than a test is to make it raise in `:test`.

## Best Next Test

Start with **#1, the Bash bypass of the main-checkout rule**.

- It has the highest impact: it breaks the one boundary the mice depend on.
- It is confirmed by running the parser, not inferred.
- It is a table of pure unit cases in an existing test file, so it is the cheapest to
  write.
- Its fix (clean redirect and `of=` prefixes, treat `$VAR` in a mutating command as
  unknown, and resolve against the payload's `cwd`) closes both ways in at once.

#2 and #3 are close behind and also small. #2 is the same kind of risk, because it is
a trust boundary in front of a live session.

## Avoid

- More `Draft` cases built from hand-made strings that re-cover the same frame logic.
  Add real captures instead.
- More precondition cases in `cleanup_test.exs`. There are already about 30, and they
  are thorough.
- More symlink tests with live targets, more merges of the person's own hooks, and more
  byte-for-byte re-init checks. All are already covered.
- Per-migration column asserts, and more `database_path` string asserts.
- Tests for path traversal in the doorstep file name (`safe/1` already blocks it), for
  very long pointers (already cut and tested), or for two mice writing at once (the
  random file name already handles it).
- Mocking Exqlite or herdr's socket in the concurrency and timeout tests. The real lock
  and the real timeout are the risk.
- Tests that only count mock calls, and snapshot tests of deny messages.

## Open Questions

Only these would change the ranking:

1. **ADR-0008: at-most-once or at-least-once delivery?** The answer decides what #7
   should assert.
2. **Does Claude Code's bash mode change the box marker away from `❯`?** If yes, the
   follow-on in #3 becomes a live bug and moves up.
3. **Is ecto_sqlite3's migration lock a no-op?** If yes, #6 moves up. If no, it drops
   to the `busy_timeout` question only.
4. **Does Claude Code reset `cwd` when the shell leaves the project?** If yes, the
   `cwd` half of #1 matters less. The redirect half stands either way.

**Side finding, the opposite failure from #1:** the PreToolUse hook denied read-only
commands during this scan, calling them "edits outside the worktree". Two cases:

- a `cd <worktree>; ls`: it read `<worktree>;`, semicolon included, as a path
- a `ls`/`grep` that ended in `2>/dev/null` and touched the main checkout's `deps/`

A false deny costs less than #1's false allow, but it shares #1's fix in
`Shell.paths/1`, so the same test table should pin it.
