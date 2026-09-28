# A missing marker means deliver; `done` is delivered too, and never waits for an answer

When a mouse finishes a turn, Whiska classifies the message purely by the marker the mouse
itself wrote. No heuristics, no extra filtering, no model reading the text to decide. This
is the same "Whiska stays dumb" line drawn everywhere else: judgment belongs to the mouse
and to the human, not to the router.

The first version of this decision defined two markers — `done` and `needs-decision` — and
left their absence undefined. That was the wrong default, and this ADR supersedes it. A
model cannot be relied on to emit an exact marker every single time, so the question is
which way that failure should break. Under the old scheme a forgotten marker meant a mouse
sat waiting and nobody was ever told. **A marker is now required to be quiet, not to be
heard.**

- **No marker at all → deliver.** The mouse stopped and did not say why; that is worth
  interrupting for.
- **`done` → delivered, then closed at once.** Told as "finished", with no reply offered
  (revised 2026-09-27; see below — it was "recorded, never delivered" before).
- **`needs-decision` → delivered.** Still valid, now redundant, since absence says the
  same thing.

## Consequences

**Forgetting is the safe direction.** A mouse that forgets its marker makes noise instead
of vanishing. This is the direction every comparable decision in this design already takes:
ADR-0012 errs broad on push detection because "a false 'are you sure?' costs nothing; a
missed real push does", and ADR-0034 reasons identically about which way to be wrong.

**An unmarked stop becomes an ordinary question**, carrying the mouse's full final message
as its body, flagged as having arrived unmarked. It is answered and replied to like any
other. Delivering it as a non-blocking *notice* instead was considered and rejected: a
notice tells you something is wrong and then leaves you to go and find the mouse yourself,
whereas a question gives you a reply channel straight back into its pane — which is exactly
what a mouse that stopped for an unstated reason needs. It also keeps one code path rather
than two delivery kinds with different rules.

That an unmarked question occupies ADR-0008's delivery slot is the gate working as
designed, not a pathology: the gate exists to serialise, and a mouse that stopped without
explaining itself is more likely to need attention than one that asked politely.

**The invisible-character trick stops being load-bearing.** The marker is still prefixed
with an invisible Unicode character so it never appears when reading the transcript. The
risk flagged originally — that a model will not reliably emit it — now costs an unwanted
ping rather than silence, which is a cost worth paying rather than a hole.

`WHISKA_DEBUG=1` renders the marker visibly and logs what the hook read, for the times the
invisible character is the thing under investigation. Deliberately an environment variable
and not a "debug mode": *mode* already means a mouse's build-or-sniff state (ADR-0018), and
one word for two unrelated things is what `CONTEXT.md` exists to prevent.

**A `done` report is delivered like any other question, and closed the moment it is
sent.** This revises the original decision, which closed it on arrival and never delivered
it. In practice that meant a finished mouse vanished: its whole final report sat in the
house, readable only by someone who already knew to run `whiska questions <id>`, and the
person learned a branch was ready by going to look. The marker rule in `CLAUDE.md` asks
mice to write the complete report in the body precisely so that it is read, and a report
nobody is told about is a report nobody reads.

So `done` now enters the queue and is typed into the main session in its turn, as `🐱
feat-x finished · #N`, offering no answer. It does not wait for a reply: the owl closes it as soon as the prompt lands, so it never
holds ADR-0008's one delivery slot. That keeps one code path — a `done` is a question in
storage and in delivery, differing only in the verb and in what happens after it is
sent — rather than a second "notice" kind with its own rules, which is the trade the
unmarked case already made above. `done` is still the marker for "nothing needed from
you": it changes the line's verb and drops the reply, not whether you hear about it.

**Recording that an entry arrived unmarked is deliberate.** It is the evidence that shows
which mice forget and how often, and therefore whether the invisible-character marker is
worth keeping at all.

## Note, 2026-09-28: the line carries no command

The line shown above used to end in `read: whiska questions N`, and a `needs-decision`
line in `answer: whiska reply N "..."` besides, so the person could see what to type
next. Both were dropped: they made the line read like code. The shape is now `🐱 <branch>
<verb> · #<id> · "<pointer>" · <n> more open`, and the `whiska-delivered` skill that
`whiska init` installs (ADR-0022) recognises it and runs the read. The id stays because
answers are keyed to it (ADR-0005). What this ADR decides — that `done` is delivered,
told as "finished", and closed at once — is unchanged.
