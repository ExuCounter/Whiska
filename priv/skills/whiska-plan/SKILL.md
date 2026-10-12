---
name: whiska-plan
user-invocable: false
description: "Write the build plan: the shape of a change, as a senior engineer would put it, which the person reads beside the spec or a bug's research document before any code. Use from whiska-spec after the spec is written, or from whiska-research once a bug's fix is obvious or picked."
---

Write how the change will be built, so the person can catch a wrong approach before it
costs a rebuild. It is the shape of the change, not a step-by-step plan: where it lands,
what it adds or changes that others depend on, how it will be tested, and the approach
you turned down.

**When:** after the spec is written, before its question goes out (`whiska-spec`); for a
bug, once the research document's fix is agreed or obvious (`whiska-research`). Every
brief that gets a spec gets one, and every bug; an investigation does not.

## Rules

- **A few lines for a small change, one screen at most.** Longer means the brief holds more
  than one build: say so in the question and name the split.
- **Text.** Code only for interfaces (signatures, command flags), data shapes (a column, a
  JSON field, a file format, a 3 to 5 line example) and output the user sees. Never
  function bodies or step-by-step code.
- **A diagram only when the change moves data across three or more parts**; otherwise
  none.
- **Use the glossary's words**, and cite the ADR behind each choice an ADR already covers.
- **Never name it in the spec or the research document.** The cold review reads those and
  holds the diff against them; it never reads this, so it judges what was built against
  what the person wanted, not against your plan.

## Where it goes

`.whiska-plan.md` at the worktree root, the folder `git rev-parse --show-toplevel` names.
It is never committed. Whiska makes git ignore it; check with
`git check-ignore -q .whiska-plan.md`. That fails → in a worktree, never write the exclude
file yourself: say in one line under the question that the line `/.whiska-plan.md`
belongs in the main checkout's `.git/info/exclude`. In the main checkout, add it yourself.

The skill that sent you here sends its link: `whiska spec-link` prints a line for it.

## While building

The build plan is what was agreed, beside the spec. A costly change to it is a decision for
the person: a different approach, an interface, a file format, stored data. Stop and ask,
as for any costly choice. A cheap one goes in the final report.

<plan-template>

# Build plan: <the spec's or research document's title>

## Where it lives

The parts of the system the change lands in, and what each one gains or loses, in a line
each. Modules and files are fine here; this is not the spec.

## Interfaces and data

Each interface added or changed, each stored thing or file format, each piece of output
the user sees: its shape, with code only as the rules above allow. Nothing changes →
"Nothing."

## Testing

The seam, the first failing test, and prior art, in a few lines. The highest seam
possible, an existing one over a new one; the fewer seams the better, ideally one. Their
ok on it is their ok on the seams. A good test checks external behaviour, not
implementation details.

## Rejected approach

The approach you turned down and why, in a line or two. With no real alternative, say so.

</plan-template>
