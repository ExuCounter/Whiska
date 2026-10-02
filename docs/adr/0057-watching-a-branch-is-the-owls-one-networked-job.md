---
status: proposed
---

# Watching a branch is the owl's one networked job, and it only ever reads

**Supersedes [ADR-0032](0032-pr-opening-and-merge-tracking.md)**, which worked out the
same idea for GitHub alone, through `gh`, with Whiska running `gh pr merge` itself.
Everything below keeps its shape and changes two things that do not survive contact: the
forge is not always GitHub, and Whiska reads but never writes.

Nothing here is built. It is recorded so it is not redesigned from scratch.

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
| Who is asked | local git, in the worktree | a forge, over the network |
| Credentials | none | a read-only forge token |
| Answer | deterministic, always available | three-valued, often unavailable |
| Failure | there is none to speak of | rate limit, outage, expired token |
| Wants the mouse | gone — it ends the mouse's life | alive — it has work to send it |
| Blocked on | ADR-0007 (nothing is ever deleted) | ADR-0044 (what Whiska may type into) |

The last row but one is the one that settles it. Watching wants a mouse's pane kept open
so a red build can go back to the session that still has the context; cleanup wants the
worktree gone. They pull in opposite directions on the same mouse, and a feature cannot
want both.

They do chain: a green build is what makes a branch mergeable, a merge is what makes
cleanup legal, so built together they run watch → merge → cleanup. A chain of two
features is not one feature. Cleanup ships first and alone, because it is offline,
deterministic and useful on its own; watching is a second thing that happens to end where
cleanup begins. Building them as one makes the offline half inherit the networked half's
failure modes — a worktree that cannot be taken down because a forge is rate-limiting
would be an absurdity.

## The split: the mouse writes, the owl reads

This is the design, and it is a security boundary before it is a convenience.

- **The mouse pushes and opens the merge request**, with its own tools, under its own
  `PreToolUse` rules and the existing push approval. Write credentials stay exactly where
  they are today and Whiska never acquires one.
- **The owl only reads status.** It cannot push, merge, comment, close or re-run, because
  the credential it holds cannot do those things — not because the code does not call
  them.
- **On red**, the failure goes to the mouse that owns the branch while that mouse is
  alive, and becomes a question for the person when it is dead. Same ladder as everything
  else in ADR-0026: cheap fixes before bothering the person.

That the owl's credential is *read-only* is the part doing the work. A token that can only
read is the enforcement; everything else is a promise.

## Credentials: a read-only token through `curl`, not a forge CLI

**`gh` is not installed on this machine, and neither is `glab`.** `curl` and `jq` are.
This repo is GitHub and the work repo is GitLab, so any version of this needs both forges
reachable. Three ways to get there:

1. **Install `gh` and `glab` and shell out to them** — ADR-0032's assumption. Rejected,
   and the reason is the split above, not the install: `gh auth login` mints a credential
   that can push, merge, comment and delete. Handing the owl a forge CLI hands it a
   write-capable credential, and the read-only boundary becomes a promise about which
   subcommands the code calls. Two interactive logins to maintain, for a GET.
2. **An HTTP client in the owl** — `req`, which brings `finch`, `mint` and a CA bundle
   into an escript that today depends on Ecto and SQLite and nothing else. Rejected: a
   TLS stack and a certificate store are a real dependency to carry, and the escript ships
   as one file.
3. **`curl`, with a read-only token per forge.** Recommended. One `GET` per branch per
   check, parsed with the `jq` that is already there or in Elixir. The token is a
   fine-grained GitHub PAT scoped to read Checks and Pull requests, and a GitLab personal
   token with `read_api`, each in `~/.whiska/forge/<host>` at `0600`, written by the
   person and never by Whiska.

The token is passed to `curl` in a header read from a file (`--config` or `@-`), never on
a command line and never in the environment Whiska builds, so it cannot reach a process
listing, the owl's log, a crash dump, or a mouse's transcript.

`whiska doctor` gains a line per watched repo: the token file exists, its mode is `0600`,
and one cheap authenticated call succeeds. Missing or expired is a `warn`, never a `fail`
(ADR-0038) — nothing is lost when a branch is not watched.

## The forge is a port

A `Whiska.Forge` behaviour with two callbacks — `merge_request(repo, branch)` and
`checks(repo, ref)` — and two adapters, `Forge.GitHub` and `Forge.GitLab`, each one a
`curl` invocation and a parse. Nothing outside an adapter knows which forge a repo has.
Which adapter is a per-repo fact: a `forge:` line in `.whiska/dispatch.yml`, defaulting to
what the `origin` remote's host says, and `none` is a supported answer. Watching is
opt-in per repo, as ADR-0032 had it, and a repo that never opts in keeps today's owl
exactly.

## Polling is the cheap part

Agreed, and worth stating so nobody optimises it. The owl is already a daemon with a
timer: it renders the board every two seconds. One branch per live mouse at about once a
minute is three orders of magnitude under either forge's authenticated limit. Polling is
not a design problem here and gets no cleverness.

The three real costs are below, in the order they bite.

### Cost 1: the owl gains a dependency it has never had

The owl touches its own files, herdr's socket, and the process table. It makes no outbound
connection to anything. That is the change, and everything here exists to keep it from
spreading.

- **Every forge call is a short-lived `Task` under the house, never the house's own
  process**, with a hard timeout (10 s) and the result delivered as a message. A forge
  that hangs must not delay a collection or a delivery by one millisecond.
- **Watching rides the existing 60 s backstop** rather than adding a timer — but unlike
  collection, the backstop is this feature's *working* trigger, not its last resort,
  because nothing tells the owl a build turned red. The house's existing backstop warning
  (ADR-0036) must stay about collection, or the signal it was built to give is lost.
- **A `curl` that cannot be run at all is an answer**, not a crash: the branch goes
  unknown and backs off.

### Cost 2: network failure must not become a false alarm

A check run is **green**, **red**, or **unknown**. Unknown is a first-class answer: no run
started yet, the network is down, the token expired, the forge is rate-limiting, or the
adapter did not recognise what came back.

- **Unknown never produces a question, ever.** It backs off — starting at the backstop
  interval, doubling to a 15-minute ceiling — and is reported on the mouse's board row and
  a doctor line. The one failure that would destroy this feature's credibility is telling
  the person a build is broken when the truth is that a laptop was on a train.
- **A rate-limit answer is obeyed, not retried**: GitHub's reset time on a 403, GitLab's
  `Retry-After` on a 429. A bug that retries into a limit gets the person throttled across
  every tool they use, not just this one.
- **A watch gives up** after a ceiling of consecutive unknowns, and says so. It is never
  resumed silently.
- **The owl being offline costs nothing.** A watch is state on a row, not a held
  connection, so a laptop that slept through a CI run reads the final result when it
  wakes.

### Cost 3: credentials

Above. It is the reason the recommendation is `curl` and not a CLI.

## Where it is blocked: typing into a mouse's pane

Nothing in Whiska types into a mouse's pane today. Delivery types into one place only —
the main session of the question's own house — and ADR-0044 put it in the broadest terms:
"nothing in Whiska types into a session that is not its own house's main session".

That rule was written against a nudge into a *person's* session, where the cost was a turn
the person paid for and a model improvising on a prompt that was not theirs. A mouse is
the opposite case: it exists to be given work, and ADR-0026's corrective nudge into a
stuck mouse's own pane is already the same shape, designed and unbuilt. The reasoning may
well not hold here — but the letter of ADR-0044 does, so this records the gate rather than
stepping over it. **Building this half means reopening ADR-0044 first**, deliberately,
with that corrective nudge in the same conversation.

Two things follow if it is reopened:

- **A question the owl originates is new.** Every question today is a mouse's own message,
  collected from the doorstep (ADR-0036). A red build is Whiska speaking. It needs its own
  kind, it is keyed by `mouse_id` like everything else, and `CONTEXT.md`'s **Question**
  entry has to say that one kind of question is not a mouse's.
- **A dead mouse escalates to the person**, through the ordinary delivery path — the one
  case where a red build reaches the person at all, and the same thing ADR-0026 already
  does with everything a dead mouse leaves behind.

## A forge's output is untrusted text

A failing job's log is written by whatever the branch under test executed. Pasting it into
a mouse's pane is handing arbitrary text to a model as if Whiska had said it — the same
class of mistake as a check command arriving with the branch under review, which ADR-0049's
finishing escalates to the person rather than running.

**So what is typed carries the job's name and URL, never the log body.** The mouse fetches
the log with its own tools, under its own `PreToolUse` rules, where it is something the
mouse read rather than something Whiska asserted. Same for a merge request's title and
description.

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
turn, which means it is a `CLAUDE.md` rule and not a feature Whiska can ship, switch off,
or report on.

**Where I disagree with dismissing it, and where I disagree with it:** the context
advantage is real but is almost entirely recovered by the split above. A mouse whose pane
is open and idle has its context and costs nothing until something is typed into it — so
the owl typing a red build into a live mouse's pane buys `/loop`'s one advantage without
paying for a single wake. What is left of `/loop`'s edge is the case where the mouse's
pane has closed, and there `/loop` is already dead too.

So: **not the leading candidate, and not useless either.** It is the version of this
feature for someone who wants no watching daemon at all, and it is worth writing into the
block as a thing a mouse *may* do for a short, bounded wait it chose itself — a merge
request it expects to go green in four minutes. It is not the mechanism for "watch this
branch until it lands", because the two things it cannot survive, a closed pane and a
sleeping laptop, are the whole reason the feature exists.

## How it composes with cleanup

- *Which branch does this mouse own, and is it merged* is asked by both and written once.
- **A branch with an open watch is not cleaned up.** A build still running is a reason to
  leave a worktree standing.
- **A merge ends every watch on that branch**, with no further forge call: merged is a
  local git fact, and the offline answer wins whenever both are available.
- If cleanup stays person-triggered, watching composes with it by producing the question
  the person acts on — green, mergeable, nothing left to do — and nothing else changes.

## Considered options

**Webhooks instead of polling.** Rejected: an inbound endpoint means a public URL or a
tunnel, a far larger change to a daemon that listens on nothing, for latency measured
against a timer nobody is watching.

**`gh pr checks --watch`**, holding the connection until the run finishes. Rejected with
the CLIs: a held process per branch, no GitLab equivalent of the same shape, and a
write-capable credential.

**Whiska running the merge itself**, as ADR-0032 had it. Rejected: it is the one write
that would force a write-capable credential into the owl, and it buys a keystroke.

**One adapter, GitHub only.** Rejected by the brief. The port costs two functions behind a
behaviour, and the second adapter is written when the work repo needs it.
