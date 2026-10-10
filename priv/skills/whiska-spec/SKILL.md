---
name: whiska-spec
description: "Write down what a brief will build, as a spec the person reads and approves before any code. Use after the last grilling round is answered, or straight away when there was nothing to ask, or on /whiska-spec."
---

Turn the grilling that just finished, if any, and what you read of the code, into a spec,
then wait for the person's ok before building. The grilling already asked everything:
synthesize what you know, and ask the person nothing new.

**When:** after the last grilling round is answered, or straight away when there was
nothing to ask, before any code. Only four briefs skip it, and there the person's own words
are the spec: a typo, or a comment or doc no program reads; a formatting or lint fix; a
test-only change; a brief that spells out the exact change. Size never skips it, and
neither does having nothing to grill. A change that hides, drops or skips anything, or
touches secrets, access or a security check, is never one of the four.

## Steps

1. **Read the code**, if you have not already: the current state of the codebase. Use the project's glossary terms throughout the spec, and respect any ADRs in
   that area.
2. **Choose the test seams.** The highest seam possible; an existing seam over a new one;
   a new one proposed as high as it can go. The fewer seams across the codebase the
   better — the ideal number is one. They go under Testing Decisions, so the person's ok
   on the spec is their ok on the seams.
3. **Keep to the brief.** Write what the brief asked for. Anything more the code suggests
   is one line under Out of Scope, as a follow-up. The spec fits on one screen, about 500
   words. Longer means the brief holds more than one build: say so above the spec and name
   the split.
4. **Write the spec** from the template below to `.whiska-spec.md` at the worktree root,
   the folder `git rev-parse --show-toplevel` names. It is never committed. Whiska makes
   git ignore it when it sets the worktree up; check with
   `git check-ignore -q .whiska-spec.md`. That fails → git sees the file as a change, and
   a worktree with a change in it is never cleaned up after its merge:
   - In a worktree, never write the exclude file yourself: it sits in the main checkout,
     which a worktree session never edits. Say so in one line under the spec: the line
     `/.whiska-spec.md` belongs in the main checkout's `.git/info/exclude`.
   - In the main checkout, add the line to `.git/info/exclude` yourself.
5. **Ask.** Send a link to the spec to the person as the question, and build only after
   they say ok. Never paste the spec into the message; the person opens the link. The
   message is one line,
   `Review spec here: [<spec title>](file://<abs path>/.whiska-spec.md)`, a link whose text
   is the spec's title, `<abs path>` being this worktree's own absolute path with its leading
   slash; then the pointer "ok to build?", above the decision marker a mouse's rules
   describe, in a worktree. "ok" → build. Anything else → change the file to match and
   send the link again.
6. **Build to it.** While building, the spec is what was agreed. A costly choice it does
   not settle is a new decision for the person, not a quiet edit to the file.

<spec-template>

## Problem Statement

The problem that the user is facing, from the user's perspective.

## Solution

The solution to the problem, from the user's perspective.

## What Changes for Users

Every behaviour a user or a calling program sees differently after this build, one line
each: a response, a message, data shown or stored. Anything hidden, dropped, skipped, or
turned from an error into silence is one of them. Nothing changes → write "Nothing." The
section is never left out.

## User Stories

A numbered list, one story per behaviour the person or their users will notice, ten at
most. Each in the format:

1. As an <actor>, I want a <feature>, so that <benefit>

<user-story-example>
1. As a mobile bank customer, I want to see balance on my accounts, so that I can make better informed decisions about my spending
</user-story-example>

A story whose actor is a mouse, the main session or a future reader is an implementation
step: drop it.

## Implementation Decisions

The choices the build rests on, the costly ones first, then any cheap one that had a real
alternative, one line each: the one taken, the alternative passed over, and the ADR that
governs it. Commands, module names, wire formats and docs upkeep are left to the build.

Do NOT include specific file paths or code snippets. They may end up being outdated very quickly.

Exception: if a prototype produced a snippet that encodes a decision more precisely than prose can (state machine, reducer, schema, type shape), inline it within the relevant decision and note briefly that it came from a prototype. Trim to the decision-rich parts, not a working demo, just the important bits.

## Testing Decisions

The seam, the first failing test, and prior art in one line. A good test checks external
behavior, not implementation details.

## Out of Scope

The things out of scope for this spec, and anything more the code suggests: one line each, as a follow-up.

## Further Notes

Only what changes the person's ok. Grilling answers appear once, as decisions.

</spec-template>
