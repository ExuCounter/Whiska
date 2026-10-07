# Every spec is kept in the main checkout, copied when it is sent

ADR-0076 put the spec in `.whiska-spec.md`, a file git ignores at the worktree root, and
accepted that it goes when the worktree goes: "once the branch lands, the commits hold the
outcome". In practice the person wanted to read specs later, and a dropped branch has no
commits at all. The copy sent as a question survives in the house, but only someone who
remembers the question number can find it.

## The rule

Every spec a mouse sends is kept in `.whiska/specs/` in the main checkout, one file per
spec, named `<date first written>-<branch, with / as ->.md`. Two mice on one branch name
on the same day keep two files, the second with `-2`. A short header says which repo,
branch and mouse it belongs to, the question it was last sent as, the questions earlier
revisions were sent as (`replaced:`), when it was written, and its status: `waiting`,
`landed <date>, branch head <commit>` or `dropped <date>`.

A revision overwrites its file. Each earlier revision is still readable whole as its own
question (`whiska show <id>`), so the folder holds only the current spec. A folder per
branch with one file per revision was the alternative. The person picked one file: specs
are overwritten anyway.

## The copy is taken when the spec is sent

The `Stop` hook reads the worktree's spec into the doorstep entry it writes, beside the
message. The doorstep is in the house and outlives the worktree (ADR-0036). When the owl
collects the entry, it writes the copy and names the question just recorded. An entry whose
spec matches the kept copy writes nothing, so the done report that follows a spec moves
nothing.

The alternatives:

- **Copy at removal.** The owl's sweep, `drop-worktree` and Land here would each have to
  remember to copy, and a worktree removed by hand would still lose its spec.
- **The mouse copies it.** A mouse never writes to the main checkout (ADR-0013).

Only a regular UTF-8 file of at most 256 KB travels. Anything else — a pipe, a binary,
something huge — is left out, so the message itself still reaches the doorstep.

Taking the copy when the spec is sent means no removal path changes. Both writers of the
entry, the owl and the escript when the owl is down, share the code that reads the spec.

## Landed and dropped

The cleanup sweep updates the status after it notes landings (ADR-0064). A mouse stamped
landed gets `landed`, with the branch's last commit. Land here cherry-picks, so main holds
copies of that commit under other ids, which is why the header calls it the branch's head.
A mouse whose worktree is gone with no landing gets `dropped`. A dropped spec is kept
(ADR-0007), and it can still become landed: a landing is noted from the branch alone after
the worktree goes. Landed is final.

A mouse whose folder a newer mouse took counts as gone too, though the folder stands.

The sweep runs only while the house has a herdr socket, so a house without one leaves
every status at `waiting`.

The status is only as right as the sweep's own landing check. A branch landed by
cherry-pick is not an ancestor of the base, so until that check learns cherry-picks, such
a spec reads `dropped`.

## Ignored without a committed file

`/.whiska/` goes into the main checkout's `.git/info/exclude`, the same local file
ADR-0076 uses for the spec. The owl writes the line the first time it keeps a spec, as
Whiska's own process. No committed file changes (ADR-0056).

## Consequences

ADR-0076's "the spec goes with the worktree" now holds only for the working copy. A spec
from before this change was never copied.

A doorstep entry gains an optional `spec` field. An entry written without one still
decodes.
