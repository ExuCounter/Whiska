# Watching a branch is the owl's one networked job, and it only ever reads

Three slices are built. The merge, seen through git
([ADR-0087](0087-an-opened-merge-request-is-remembered.md)): while a merge request Whiska
recorded waits, the owl fetches its base branch, and cleanup reads a landing from that
fetched copy. And the reading of a GitLab merge request every minute, through the forge
layer below: its state, its head pipeline, its open threads and its new comments, shown
on the mouse's sidebar row (ADR-0082). And new review handed to the branch's mouse as a
review round (below): woken in its pane if it is live, started in its worktree if not. An
earlier draft worked
the same idea out for GitHub alone, through `gh`, with Whiska running `gh pr merge`
itself; two things in it did not survive contact: the forge is not always GitHub, and
Whiska reads but never writes.

## The question this starts from

Whiska follows a mouse from spawn to its last message and then stops caring. Two things
happen after that message today, both by hand: a landed branch's worktree is taken down,
and a branch whose build went red is noticed by the person and carried back to the mouse
that wrote it.

They look like one feature — *the owl follows a mouse's work after the last message* —
and they are not.

## One feature or two

**Two, and the read/write split below pushes them further apart rather than closer.**
What they share is one question — which branch does this mouse own — and nothing else:

| | Cleanup after a merge | Watching checks |
|---|---|---|
| Who is asked | git: the base here, or its copy last fetched | a forge, over the network |
| Credentials | none of Whiska's; a fetch uses git's own and never prompts | the person's `glab` login, through a GET-only runner |
| Answer | deterministic; the fetched copy only as fresh as its last fetch | three-valued, often unavailable |
| Failure | a fetch that fails leaves the last answer standing | rate limit, outage, expired token |
| Wants the mouse | gone — it ends the mouse's life | alive — it has work to send it |
| Blocked on | nothing: built (ADR-0061) | nothing: built, through ADR-0044's review exceptions |

The last row but one is the one that settles it. Watching wants a mouse's pane kept open
so a red build can go back to the session that still has the context; cleanup wants the
worktree gone. They pull in opposite directions on the same mouse, and a feature cannot
want both.

They do chain: a green build is what makes a branch mergeable, a merge is what makes
cleanup legal, so built together they run watch → merge → cleanup. A chain of two
features is not one feature. Cleanup ships first and alone, because it needs no forge, is
deterministic and useful on its own; watching is a second thing that happens to end where
cleanup begins. Building them as one makes the forge-free half inherit the networked half's
failure modes — a worktree that cannot be taken down because a forge is rate-limiting
would be an absurdity.

## The split: the mouse writes, the owl reads

This is the design, and it is a security boundary before it is a convenience.

- **The mouse pushes and opens the merge request**, with `gh` or `glab`, under its own
  `PreToolUse` rules and the existing push approval. Write credentials stay exactly where
  they are today and Whiska never acquires one.
- **The owl only reads status.** It cannot push, merge, comment, close or re-run: the one
  runner it reads through builds a `GET` and nothing else (below).
- **On new review**, a failed pipeline or a member's comment goes to the mouse that owns
  the branch while that mouse is alive, and to a mouse the owl starts on the branch when it
  is not. The person is asked only when that cannot be done (below). Same ladder as
  everything else in ADR-0026: cheap fixes before bothering the person.

## Credentials: the person's own login, read through one GET-only runner

This repo is GitHub and the work repo is GitLab, so any version of this needs both forges
reachable. The first design gave each half its own credential; the reading half was
changed on 2026-10-14, and the first design is kept below as the way back.

- **The mouse writes through `gh` / `glab`,** as it always did, and `whiska pr` opens
  through the same login (ADR-0088).
- **The owl reads through the same `glab` login, through one runner.**
  `Whiska.Forge.CLI` is the only place the owl runs a forge's tool, and the argument list
  it builds is fixed: `api --method GET --include --hostname <host> <path>`. The host and
  the path are each checked against a closed set of characters, with no `..`, so nothing
  read from a forge or a record can add a flag or reach another verb. A test pins the
  argument list. The tool must be named by an absolute path. It runs with no prompt and no
  update check, through a port with a deadline and a kill, its stderr dropped, its HTTP
  status read from `--include`, and the person's own PATH ahead of the places a package
  manager puts a tool.
- **A request is read only for the branch it came from.** A merge request whose source
  branch is not the mouse's branch reads as unknown and nothing more is asked of it, so a
  link recorded for the wrong branch never speaks for that branch.

**Why the login and not a token.** A token is one more secret the person writes and
renews, for a boundary the first design itself admitted the operating system never
enforced (its honest limit, below): the person's `glab` is on the same machine either
way. What carries the weight now is that the owl's only way to a forge builds a `GET`.
That is weaker than a token that cannot write, and stronger than a promise about which
subcommands the code calls: a bug elsewhere in the owl has no runner that writes.

### The first design, kept as the way back

**Each half used the tool that fits what it is allowed to do:**

- **The mouse writes through `gh` / `glab`.** Opening a merge request means a title, a
  body, a base and a head, and reading back a number — `gh pr create` and `glab mr create`
  are each one line where hand-rolled HTTP would be a request builder, a JSON body, an
  error taxonomy and two API versions to track, for the half that is *meant* to have write
  access. The person authenticates each CLI once, with `gh auth login` and `glab auth
  login`, and that credential stays where that forge's own tooling expects it. Whiska
  neither stores it nor reads it.
- **The owl read through `curl` and a read-only token.** A status check is one `GET` per
  branch, parsed with the `jq` that is already there or in Elixir. The token is a
  fine-grained GitHub PAT scoped to read Checks and Pull requests, and a GitLab personal
  token with `read_api`, each in `~/.whiska/forge/<host>` at `0600`, written by the person
  and never by Whiska.

**Its reason for not reusing the CLI was the split, not the install.** `gh
auth login` mints a credential that can push, merge, comment and delete. Polling through
it would hand the always-awake half a write-capable credential and reduce the read-only
boundary to a promise about which subcommands the code happens to call. A token that can
only read is the one version of that boundary which survives a bug.

**The honest limit:** the owl runs as the person, and the person's `gh` is on the same
machine with the same file permissions, so this is not an OS-level barrier — nothing stops
a future line of code from invoking `gh` directly. What it buys is that the owl's own
adapters have no write verb and need no write credential to do their job, so the
destructive capability is never in reach of the code path that polls. That is worth having
and worth not overclaiming.

Rejected along the way: **an HTTP client inside the owl** — `req`, which brings `finch`,
`mint` and a CA bundle into an escript that today depends on Ecto and SQLite and nothing
else. A TLS stack and a certificate store are a real dependency to carry, and the escript
ships as one file.

The token is passed to `curl` in a header read from a file (`--config` or `@-`), never on
a command line and never in the environment Whiska builds, so it cannot reach a process
listing, the owl's log, a crash dump, or a mouse's transcript.

A reader with a token would be one more module behind the same interface, should the
login ever prove the wrong trade.

`whiska doctor` gains a forge line while a GitLab merge request waits: `glab` not found,
or reads failing for three minutes or more, each named with why, with `glab auth login
--hostname <host>` when the forge refused for want of a sign-in. It reads what the owl
stored and makes no call to the forge. Missing or failing is a `warn`, never a `fail`
(ADR-0038): nothing is lost when a branch is not read.

## The forge is a port

`Whiska.Forge` is the behaviour, and an adapter per forge knows everything about it:
parsing its links, naming a request (`!7`, `#12`), and the reads. The reads are
`merge_request` (its state, head commit, head pipeline, ready to merge or its one blocker, notes count and
last update), `notes` (the open threads and the comments past a cursor, a page of 100 at a
time, at most 20 pages, following `X-Next-Page`), `member?`, `me` and `project_readable?`.
`whiska pr`'s half is a separate behaviour, `Whiska.Forge.Opener`, which only `whiska pr`
calls, in the CLI process, never the owl.

- **`Forge.GitLab`** reads and opens. **`Forge.GitHub`** opens only; a GitHub link is not
  read yet, and its row shows its name alone. Its threads' resolution exists only in
  GraphQL, which is always a `POST`, so reading it is a decision for when it is built.
- **Which adapter is picked by the recorded link's host**, and for opening by the `origin`
  remote's. There is no `dispatch.yml` and no opt-in: ADR-0085 has no settings place, and a
  repo with no recorded GitLab link makes no forge call at all.
- **Tests fake the tool, not the module**: a `glab` script on disk, handed to the house as
  its `:forge_tools`, and `config/test.exs` names no tool, so no test reaches a real forge
  (ADR-0031).

## Polling is the cheap part

Agreed, and worth stating so nobody optimises it. The owl is already a daemon with a
timer: it renders the board every two seconds. One branch per live mouse at about once a
minute is three orders of magnitude under either forge's authenticated limit. Polling is
not a design problem here and gets no cleverness.

Each waiting GitLab request costs one `GET` a minute, and the threads are read only on the
first read, when its notes count or last update moved, or while a thread is open, since
resolving one may move nothing else. Ten waiting requests are about 600 to 1,200 calls an
hour.

The three real costs are below, in the order they bite.

### Cost 1: the owl gains a dependency it has never had

The owl touches its own files, herdr's socket, the process table, one git remote for the
fetch of a base branch, and the forge for each GitLab request recorded. Everything here
exists to keep that from spreading.

- **Every forge call is a short-lived `Task` under the house, never the house's own
  process**, with a 30 s deadline per call and the result delivered as a message. A forge
  that hangs must not delay a collection or a delivery by one millisecond. The task does
  the network only: the house reads the stored reads before and writes them after.
- **Reading rides the existing 60 s backstop** rather than adding a timer, each request
  due 60 s after its last read started — but unlike collection, the backstop is this
  feature's *working* trigger, not its last resort, because nothing tells the owl a build
  turned red. The house's existing backstop warning (ADR-0036) stays about collection.
- **A tool that cannot be run at all is an answer**, not a crash: the read goes unknown
  and backs off.

### Cost 2: network failure must not become a false alarm

A check run is **green**, **red**, or **unknown**. Unknown is a first-class answer: no run
started yet, the network is down, the token expired, the forge is rate-limiting, or the
adapter did not recognise what came back.

- **Unknown never produces a question, ever.** The last read stands, the owl's log says so
  once, and the next read waits as long as reads have been failing, between 60 s and a
  15-minute ceiling. After three minutes the mouse's row says `unread <age>`, and the doctor
  line names it. The one failure that would destroy this feature's credibility is telling
  the person a build is broken when the truth is that a laptop was on a train.
- **A rate-limit answer is obeyed, not retried**: GitLab's `Retry-After` on a 429, up to
  an hour, and for every request on that host in the same round. A bug that retries into a
  limit gets the person throttled across every tool they use.
- **A read never gives up while the request is open**: a merge request the person still
  has open is worth reading after an outage, and the row already says it is unread.
- **A 404 is deleted only after three in a row, only while the project itself still
  reads, and only for a request once read as the mouse's.** A project that does not read
  is a sign-in or access problem, which is unknown; a link that never read says nothing
  about the branch.
- **What cannot be kept is unknown**: a reply past 16 MB, or a number past what the
  house's SQLite stores. An open thread is one with a note still to resolve, as GitLab
  marks resolution on each note.
- **The owl being offline costs nothing.** A read is a row, not a held connection, so a
  laptop that slept through a CI run reads the final result when it wakes. What the owl
  last read is kept in the house, with the newest comment it has seen, so a restart never
  counts the same comment twice.

## What counts, and what is said

- **A new comment** is one past the cursor, not a system note, not by the signed-in
  account, and by a member of the project; membership is asked once per author and
  remembered while the owl runs. A comment already there at the owl's first read of a
  request is not new.
- **An open thread** counts once, whatever its age, the first time the owl reads it with
  its newest note by a member other than the signed-in account, and no round has had it.
  A thread whose last word is the account's was answered, by the person or by a mouse
  posting as them, so it never counts. Each thread a review names is remembered on the
  read's row, by id, so one a round left open comes back only through a new comment in
  it, and never loops. Without this, a thread written before the cursor, or before
  review was handed over at all, stayed open with nobody told.
- **A failed pipeline** counts once per pipeline, and only when it ran on the request's
  head commit, one already failed at the first read included.
- **Each is kept on the read's row**, by id, until a review round takes it, and logged at
  the read that sees it with what became of it: `feat/x: review for !123 — 2 new comments
  by alice, bob; 1 open thread by bot; pipeline failed on 63c47262 — woke its mouse`,
  `— starting a mouse` or `— kept: <why>`.
- **Merged on the forge fetches the base at once.** The forge's word is not the landing:
  git's checks still prove it (ADR-0061).
- **Closed on the forge, or gone, asks the person once** whether to drop the worktree:
  once per close, so a request reopened and closed again is asked about again, and a
  reopening takes back a question still waiting. The ask is made from the stored read,
  stamped before the question is left, so one that failed is made at the next read. A
  branch whose name holds a space, a control character or a backtick is not asked about:
  its name would be words of its own in the question.
- **That question is the owl's, not the mouse's.** It is stored against the mouse so it
  goes with the worktree, but nothing that reads a mouse's questions as its words counts
  it: it supersedes none of the mouse's questions and none supersede it, it is not the
  mouse's last word for cleanup (ADR-0061) or pickup, and it does not stop an answer being
  handed over, chosen as the stop a hold caused, or counted in metrics. Its line and hoot
  open with `🦉 Whiska asks`, as the heading the main session writes for it does. Collection takes it as the owl's only
  when it is stamped the second the owl's stored read says it asked.

### Cost 3: credentials

Above. It is the reason the first design read through `curl` and a read-only token, and
the reason the reading half now has one runner that builds nothing but a `GET`.

## A review round: new review handed to the branch's mouse

Each minute, review kept on a read's row is handed to the branch's mouse, through the
exceptions ADR-0044 lists for it. The mouse is the opposite case from the nudge that
ADR-0044 was written against: it exists to be given work, and the work is its own merge
request coming back.

- **A live mouse is woken** when its one Claude pane is idle or done with an empty prompt
  box (ADR-0047), the same bounds as the doorbell (ADR-0080). It must not be held, have
  nothing waiting on the person (an open or sent question, or an answer not yet taken),
  have no background work out, and not have been picked up this minute. Whiska writes a
  letter in its worktree and types one fixed line naming it. The round is stamped before the
  line is typed, and put back, letter and all, if herdr refuses it.
- **With no live mouse, the owl starts one**: a build mouse on `sonnet` at `medium` effort
  with the review brief, in the branch's worktree, its first prompt the same line. A
  dropped worktree is made again only at `worktrees/<branch>`, on its branch brought up to
  `origin`'s, keeping commits not pushed; one still standing is used only when its marker
  names the mouse, and never while a session runs in it. herdr opens it without moving the
  person's view. It runs in a task, one per merge request at a time, keeps the mouse's
  `mouse_id`, and records the mouse alive only once Claude runs. A branch whose name
  cannot go in a question is never started for, since a failed start is one.
- **The round's rules** are in the letter, and in the build and review briefs. The mouse
  fixes, answers or disputes each thread and writes its replies to files. It then asks
  "Ready to push", one line per thread. Nothing is pushed, and nothing is posted to a
  person's thread, without the person's yes. A round on bots' threads alone with nothing
  to push needs none.
- **Pushed is read from git and the forge**, never from the mouse's words: the branch's
  `origin` ref or the request's head moved since the round began. The round after three in
  a row that pushed nothing is a question to the person instead. So is a mouse that could
  not be started, and one the owl started that died before saying anything. That question
  is the owl's, like a close's (below), but about the merge request rather than the
  worktree: it arrives open, and stays so, whatever became of the worktree.
  No round runs while it waits; closing it, however, starts the count afresh and hands over
  what was kept meanwhile. One that never reached the house is asked again after ten
  minutes.
- **Woken whatever its context size.** Claude Code compacts a long session, and the
  person's answer was that a fresh mouse each round was acceptable but not needed.

Owl questions, for a closed or deleted request and for a review round, are left on the
doorstep like a mouse's (ADR-0036), keyed by the mouse's `mouse_id` and recorded with
`asked_by: "owl"` only when the text is one the owl wrote and its read says it asked.

## A forge's output is untrusted text

A failing job's log is written by whatever the branch under test executed. Pasting it into
a mouse's pane is handing arbitrary text to a model as if Whiska had said it — the same
class of mistake as a check command arriving with the branch under review, which ADR-0049's
finishing escalates to the person rather than running.

**So what is typed is one fixed line naming a letter, and the letter carries links and
ids, never a comment's or a log's text.** A comment's author is the one word of the forge's
in it, cut to the characters a username is made of; a thread's id is checked against a
closed set before it is kept. The mouse reads comments and logs with its own tools, under
its own `PreToolUse` rules, where they are something the mouse read rather than something
Whiska asserted. Same for a merge request's title and description.

## The `/loop` alternative, weighed

Instead of the owl watching, the mouse opens its own merge request and then stays alive on
Claude Code's `/loop`, waking on a schedule to check it.

**Its real advantage is context.** A mouse that wakes to its own red build fixes it in
place, with the whole conversation that produced the branch still in front of it. The
owl-watching design has to send that failure to a session cold.

**Its costs**: a live session per waiting branch; tokens on every wake, whether or not
anything changed; and a loop that dies when the pane closes or the machine sleeps — which
is exactly when a person most wants something watching. And **Whiska cannot start one**:
Whiska types into panes, so looping is a decision the mouse makes at the end of its own
turn, which means it is a line in the mouse's brief and not a feature Whiska can switch
off or report on.

**Where I disagree with dismissing it, and where I disagree with it:** the context
advantage is real but is almost entirely recovered by the split above. A mouse whose pane
is open and idle has its context and costs nothing until something is typed into it — so
the owl typing a red build into a live mouse's pane buys `/loop`'s one advantage without
paying for a single wake. What is left of `/loop`'s edge is the case where the mouse's
pane has closed, and there `/loop` is already dead too.

So: **not the leading candidate, and not useless either.** It is the version of this
feature for someone who wants no watching daemon at all, and it is worth writing into the
build brief as a thing a mouse *may* do for a short, bounded wait it chose itself — a merge
request it expects to go green in four minutes. It is not the mechanism for "watch this
branch until it lands", because the two things it cannot survive, a closed pane and a
sleeping laptop, are the whole reason the feature exists.

## How it composes with cleanup

- *Which branch does this mouse own, and is it merged* is asked by both and written once.
- **A merge ends every watch on that branch**: merged is a git fact, read from the base
  here or its fetched copy, and git's answer wins whenever both are available. The forge's
  "merged" only brings the next fetch forward.
- Cleanup is the owl's and unattended (ADR-0061); a watch that ends merged simply hands
  the branch to it.

## Considered options

**Webhooks instead of polling.** Rejected: an inbound endpoint means a public URL or a
tunnel, a far larger change to a daemon that listens on nothing, for latency measured
against a timer nobody is watching.

**`gh pr checks --watch`**, holding the connection until the run finishes. Rejected: a held
process per branch, and no GitLab equivalent of the same shape.

**`curl` or Erlang's `:httpc` with a read-only token**, the first design. Kept as the way
back (above): each needs a token Whiska must hold, and `:httpc` a TLS setup in the owl.

**`glab api --paginate`.** It joins pages and drops the headers the runner reads its
status from, so the adapter follows `X-Next-Page` itself.

**Whiska running the merge itself**, as the first draft had it. Rejected: it is the one
write that would force a write-capable credential into the owl, and it buys a keystroke.

**One adapter, GitHub only.** Rejected by the task. The port costs two functions behind a
behaviour, and the second adapter is written when the work repo needs it.

Folded in on 2026-10-08: 0032 (its text is in git history).

Changed on 2026-10-14: the owl reads each GitLab merge request every minute through the
person's `glab` login and a GET-only runner, where a `curl` and a read-only token were
proposed; the forge layer is built as read and open behaviours picked by host; a read
never gives up while the request is open; and the owl asks its own question when a
request is closed or deleted, a question that is not its mouse's word. A request is read
only for its own source branch. "A branch with an open watch is not cleaned up" is
dropped: a branch git proves merged is merged, whatever a forge still shows. Waking a
mouse stays proposed.

Changed on 2026-10-14, again: new review is handed to the branch's mouse as a review
round, woken if it is live and started if not, where it was logged as what would wake it;
a dead mouse's review starts a fresh mouse rather than asking the person.

Changed on 2026-10-15: an open thread counts once whatever its age, by its newest note,
and a pipeline already failed at the first read counts, where nothing that existed at the
first read did; a bot's thread logged only as "would wake" before rounds existed sat open
with nobody told.

Changed on 2026-10-15: the merge request read also carries its one blocker, from GitLab's `detailed_merge_status`, so the sidebar can say why it cannot merge yet (ADR-0082).
