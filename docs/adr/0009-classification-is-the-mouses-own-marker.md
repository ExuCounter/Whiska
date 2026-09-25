# A question's kind is the mouse's own marker, with no filtering on top

When a mouse finishes a turn, Whiska classifies the message purely by the marker the
mouse itself wrote — `done` versus `needs-decision`. No heuristics, no extra filtering,
no model reading the text to decide. This is the same "Whiska stays dumb" line drawn
everywhere else: judgment belongs to the mouse and to the human, not to the router.

The marker is prefixed with an invisible Unicode character (the same trick firstmate
uses) so it never appears when reading the transcript — only the hook sees it.

## Consequences

A `done` report is a question in name and storage only: closed on arrival, never
delivered, never answered.

Real risk, flagged rather than hidden: getting a model to reliably emit an exact
invisible character every single time is not guaranteed the way plain text is.
