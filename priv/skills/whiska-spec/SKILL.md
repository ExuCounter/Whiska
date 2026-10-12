---
name: whiska-spec
user-invocable: false
description: "Write down what a brief will build, as a spec the person reads and approves before any code. Use after the last grilling round is answered, or straight away when there was nothing to ask."
---

Turn the grilling that just finished, if any, and what you read of the code, into a spec,
then wait for the person's ok before building. The grilling already asked everything:
synthesize what you know, and ask the person nothing new.

**When:** after the last grilling round is answered, or straight away when there was
nothing to ask, before any code. Only four briefs skip it, and there the person's own words
are the spec: a typo, or a comment or doc no program reads; a formatting or lint fix; a
test-only change; a brief that spells out the exact change. Size never skips it, and
neither does having nothing to grill. A change that hides, drops or skips anything, or
touches secrets, access or a security check, is never one of the four. A bug, whose fix
changes nothing beyond what is wrong, gets a research document from `whiska-research`
instead.

## Steps

1. **Read the code**, if you have not already: the current state of the codebase. Use the project's glossary terms throughout the spec, and respect any ADRs in
   that area.
2. **Keep to the brief.** Write what the brief asked for. Anything more the code suggests
   is one line under Out of Scope, as a follow-up. The spec fits on one screen, about 500
   words. Longer means the brief holds more than one build: say so above the spec and name
   the split.
3. **Write the spec** from the template below to `.whiska-spec.md` at the worktree root,
   the folder `git rev-parse --show-toplevel` names. It is never committed. Whiska makes
   git ignore it when it sets the worktree up; check with
   `git check-ignore -q .whiska-spec.md`. That fails → git sees the file as a change, and
   a worktree with a change in it is never cleaned up after its merge:
   - In a worktree, never write the exclude file yourself: it sits in the main checkout,
     which a worktree session never edits. Say so in one line under the spec: the line
     `/.whiska-spec.md` belongs in the main checkout's `.git/info/exclude`.
   - In the main checkout, add the line to `.git/info/exclude` yourself.
4. **Write the build plan:** run `whiska-plan`. How the change is built goes there, never
   in the spec.
5. **Ask.** Send a link to the spec to the person as the question, with the build plan's
   beside it, and build only after they say ok to both. Never paste the spec or the build
   plan into the message; the person opens the links. The message is
   `Review spec here: [<spec title>](<link>)` and, under it,
   `Review build plan here: [<spec title>](<link>)`. Never type the lines yourself: run
   `whiska spec-link '<spec title>'` from the worktree, the title in single quotes with
   each `'` in it written `'\''`, and send what it prints. It links this worktree's own
   files, or the viewer the person's own setting names. Then the pointer "ok to build?",
   above the decision marker a mouse's rules describe, in a worktree. "ok" → build.
   Anything else → change the file to match and send the link again.
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

## Decisions

The choices a user or a calling program sees, and the person's grilling answers, the
costly ones first, one line each: the one taken, the alternative passed over, and the ADR
that governs it. Test seams, the first failing test, where the code lives, internal
interfaces and the rejected approach go to the build plan, never here.

Do NOT include specific file paths or code snippets. They may end up being outdated very quickly.

## Out of Scope

The things out of scope for this spec, and anything more the code suggests: one line each, as a follow-up.

## Further Notes

Only what changes the person's ok. Grilling answers appear once, as decisions.

</spec-template>
