---
name: whiska-research
user-invocable: false
description: "Write the research document: for a bug, its proof, cause and fix options, which the person oks before any code; for an investigation, what it found and proposes. Use for a brief that reports something working wrong, and at the end of an investigation."
---

One document for work that has to be found out before it is built. Its sections switch on
by the kind of work: a **bug**, or an **investigation**.

## A bug

A bug is something working wrong where the fix changes nothing beyond it. A fix that
changes behaviour beyond the bug is a feature: go to `grilling` and `whiska-spec` instead,
and say why in one line.

1. **Reproduce it with a failing test first.** The test is the evidence of the cause. You
   cannot reproduce it → write the research document with what you tried and no fix, and
   end on a question: what would reproduce it, or whether to go on.
2. **Find the cause**, and every other behaviour the fix touches. One a user would notice
   makes it a feature, above.
3. **Write the research document** from the template, with the bug's sections. Options
   only when there is a real choice; one obvious fix → the cause, the fix and the test.
   Never name the build plan in it: the cold review holds the fix against this document,
   and never reads the build plan.
4. **Ask.**
   - One obvious fix → run `whiska-plan` too, and send both links in one question.
   - A real choice → send the research document alone, its options lettered with the one
     you recommend. After their pick, write their pick under Picked, then `whiska-plan`,
     and send the build plan in its own question.

   Never type a link: run `whiska spec-link '<title>'` from the worktree, the title in
   single quotes with each `'` in it written `'\''`, and send what it prints. Its first
   line is `Review research here: [<title>](<link>)`, then one per other document. Then the
   pointer, "ok to build?" or the pick, above the decision marker. Anything else → change
   the file to match and send the links again.
5. **Build** to the research document and the build plan, as `whiska-plan` says.

## An investigation

A turn that only investigated writes the research document with the investigation's
sections. `whiska show` links it under the branch line, so the report carries no link.
Write it with the file tool, at its absolute path, and end as `proposed-build.md` beside
`whiska-finish` says.

## Where it goes

`.whiska-research.md` at the worktree root, the folder `git rev-parse --show-toplevel`
names. It is never committed; Whiska makes git ignore it. Start it with a `# ` heading: a
link to it shows that as its title. A bug's document fits on one screen; an
investigation's holds its findings in full.

<research-template>

# <what is wrong, or what was investigated>

Kind: bug | investigation

## Question

Investigation only. What was asked, and the decision it feeds.

## Before and after

Bug only. What happens now and what should happen, as a concrete example, and the
failing test that shows it.

## Cause

Bug only. Why it happens, pointing at the code.

## Found

Investigation only. What was established, each finding with its evidence: the code, a
command and what it printed, a source.

## What else the fix affects

Bug only. Every other behaviour the fix touches, or "Nothing else."

## Fix

Bug with one obvious fix only. The fix, in a line or two.

## Options

Only when there is a real choice. Each option lettered, with what it costs, then the one
you recommend and why in a line.

## Picked

Bug only, after the person's pick: the option, in their words where they added any.

## Proposed build

Investigation only, when something should change: the block `proposed-build.md`
describes.

</research-template>
