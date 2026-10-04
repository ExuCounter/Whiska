# Model choice is a ranked list in dispatch.yml, walked reactively

**Superseded on 2026-10-03 by [ADR-0069](0069-a-mouse-is-shaped-before-it-starts.md).**
No mode has a model of its own any more: the spawning session picks the model and the
effort by the ordered rules in Whiska's `priv/models.json`
(ADR-0073), and Claude Code walks that
file's fallback chain itself. `dispatch.yml` carries no model list. What this decision
said before:

> The main session can always override model and effort per task, the same judgment call it
> already makes about whether something needs a worktree at all. The *default* comes from a
> small static config, `.whiska/dispatch.yml`, scaffolded by `whiska init` — a flat,
> tool-agnostic file the person writes — with a ranked list per mode.
>
> The list is walked reactively, not predictively. Whiska does not check quota or usage
> before spawning: that would mean integrating with whatever quota API each provider happens
> to expose, inconsistently, and some may not expose one at all. It tries the first entry,
> and only if the spawn actually fails with a real quota or rate-limit error does it try the
> next one down.
>
> ## Consequences
>
> This is the same "verify mechanically, don't guess ahead of time" principle used for push
> detection and for readiness checks. Static is deliberate: if this later needs to shift on
> real usage patterns ("prefer whichever account has quota left today"), that is a real
> feature to add on top, not something to build speculatively now.
