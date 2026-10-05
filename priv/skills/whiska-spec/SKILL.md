---
name: whiska-spec
description: "Write down what a grilled brief will build, as a spec the person reads and approves before any code. Use after the last grilling round is answered, or on /whiska-spec."
---

This skill turns the grilling that just finished, and what you read of the code, into a
spec, then waits for the person's ok before building. Do NOT interview the person: the
grilling already did. Just synthesize what you already know.

Installed by `whiska init` (Whiska ADR-next-a-grilled-brief-is-written-down-before-it-is-built).
The `CLAUDE.md` block names the trigger; the steps live here.

## When

After the last grilling round is answered, before any code. A tweak or quick fix skips it,
and so does a brief that needed no grilling: the person's own words are its spec.

## Process

1. Explore the repo to understand the current state of the codebase, if you haven't
   already. Use the project's domain glossary vocabulary throughout the spec, and respect
   any ADRs in the area you're touching.

2. Sketch out the seams at which you're going to test the feature. Existing seams should
   be preferred to new ones. Use the highest seam possible. If new seams are needed,
   propose them at the highest point you can. The fewer seams across the codebase, the
   better - the ideal number is one. They go under Testing Decisions, so the person's ok
   on the spec is their ok on the seams.

3. Write the spec using the template below to `.whiska-spec.md` at the worktree root, the
   folder `git rev-parse --show-toplevel` names. It is never committed. If
   `git check-ignore -q .whiska-spec.md` fails there, git sees the file as a change, and
   a worktree with a change in it is never cleaned up after its merge: add the line
   `/.whiska-spec.md` to the file `git rev-parse --git-path info/exclude` names, then
   check again.

4. Send the whole spec to the person as the question, and build only after they say ok.
   The message is the spec as written, with no length cap, then the pointer "Spec ready,
   see above — ok to build?" above the decision marker the block describes. "ok" → build.
   Anything else → change the file to match and send the whole spec again.

5. While building, the spec is what was agreed. A costly choice it does not settle is a
   new decision for the person, not a quiet edit to the file.

<spec-template>

## Problem Statement

The problem that the user is facing, from the user's perspective.

## Solution

The solution to the problem, from the user's perspective.

## User Stories

A LONG, numbered list of user stories. Each user story should be in the format of:

1. As an <actor>, I want a <feature>, so that <benefit>

<user-story-example>
1. As a mobile bank customer, I want to see balance on my accounts, so that I can make better informed decisions about my spending
</user-story-example>

This list of user stories should be extremely extensive and cover all aspects of the feature.

## Implementation Decisions

A list of implementation decisions that were made. This can include:

- The modules that will be built/modified
- The interfaces of those modules that will be modified
- Technical clarifications from the developer
- Architectural decisions
- Schema changes
- API contracts
- Specific interactions

Do NOT include specific file paths or code snippets. They may end up being outdated very quickly.

Exception: if a prototype produced a snippet that encodes a decision more precisely than prose can (state machine, reducer, schema, type shape), inline it within the relevant decision and note briefly that it came from a prototype. Trim to the decision-rich parts, not a working demo, just the important bits.

## Testing Decisions

A list of testing decisions that were made. Include:

- A description of what makes a good test (only test external behavior, not implementation details)
- Which modules will be tested
- Prior art for the tests (i.e. similar types of tests in the codebase)

## Out of Scope

A description of the things that are out of scope for this spec.

## Further Notes

Any further notes about the feature.

</spec-template>
