# Needs attention

Last in the report, only when you advise a step on this branch before it lands: a fix, a
follow-up change, a check the person should run. The main session turns each item into a
lettered option, so the person picks one by letter:

    **Needs attention**
    - <what needs attention and the action to take> (recommended)
    - <another item, same shape>

- One line per item: what needs attention and the action to take, in your own words and
  concrete enough to send back to you as an instruction.
- Mark at most one `(recommended)`: the one you would do first. Say nothing more about
  landing: the main session offers Land, a PR and Drop after your items.
- A **not approved** change from Against the spec is always an item, its action the fix
  that brings the change back inside the spec, and one of them carries `(recommended)`:
  landing it is the person's call, made by picking Land over it.
- Otherwise leave the block out: nothing needs attention, no change is **not approved**,
  and you would land it as it is. The person is not asked to confirm what needs no
  decision.
- The turn still ends on the finished marker, never on a decision: the block is content
  the main session reads, as it reads **Proposed build**.
