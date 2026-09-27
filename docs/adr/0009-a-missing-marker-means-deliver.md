# A missing marker means deliver; `done` is how a mouse opts out

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
- **`done` → recorded, never delivered.** The explicit opt-out, unchanged in behaviour.
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

**A `done` report remains a question in name and storage only**: closed on arrival, never
delivered, never answered.

**Recording that an entry arrived unmarked is deliberate.** It is the evidence that shows
which mice forget and how often, and therefore whether the invisible-character marker is
worth keeping at all.
