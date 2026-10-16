# Current handoff

Baselined October 16, 2026 against rebased source `f58934f91` on
`web/queue-controls`, starting from main `6430703a9`. This edition covers held-message Edit and
Remove controls. The installed daemon has not been updated.

The previous edition described history browsing and separate parent-completion
and LSP follow-ups. Those claims are historical evidence, not validation of
this branch; their recorded results remain in the
[prior handoff](https://github.com/Roasbeef/loom/blob/dc70d25d42da531284225bf399f40f82e13539d4/docs/next.md).
The project-wide plan remains `docs/issue-plan.md`.

## What changed

Each held input explicitly marked editable now offers Edit and Remove on the
operator page. Edit fetches its complete document before opening a multiline
editor with Save and Cancel. Save preserves image blocks and queue position.
Remove compares the drawn identity and revision before withdrawing one item.
It cannot affect another author's message, an updated revision or admitted work.
Protocol-change/088 records the new command and `removed` acknowledgement.
Observers draw the held text without mutation handlers.

Queue notices now survive shared ticks and focus changes until the web host
consumes them. Previously the shared step discarded them because its second
host had no queue editor. A real-wire regression caught that assumption: the
read reply was valid but the page stayed Loading. Restoring the old discard
makes the new complete-read regression fail.

The editor uses an explicitly constructed uncontrolled textarea and a keyed
held row. Browser keystrokes survive unrelated patches, neighbor removal,
refusal and history browsing. Lustre's textarea helper would create a controlled
value, so it is deliberately not used here. An uncertain save stays locked
through unrelated refusals. Opening another input while Remove owns the lane
is refused before a deferred fetch can be lost to its acknowledgement.

## Verification boundary

Rebased October 16, 2026 onto main `6430703a9`, with production sources
unchanged by conflict resolution. Main's current project-wide rulings remain
in its [handoff](https://github.com/Roasbeef/loom/blob/6430703a9/docs/next.md).
The queued-input proposal is now 088 because main already assigned 087.

The rebased tree passed all 486 shared-session tests, 1,011 web tests and 15
focused queued client tests, each with exit 0. Browser asset generation and
documentation checks passed. Independent review rechecked the integration and
found no remaining correctness issue.

A real browser connected to a freshly built isolated native daemon and a
local deterministic Anthropic SSE provider. During a held generation it queued
three messages, cancelled and reopened a multiline edit, removed one input,
and saved another carrying an image. After release, recorded provider requests
proved the removed and cancelled text absent, the saved multiline text before
the final sentinel, and its image block retained. This exercised the actual
browser, command transport, runtime queue and provider request construction.
The installed daemon was untouched.

The earlier simulated-transport Lustre browser check remains evidence for
textarea identity and cursor preservation across neighbor removal and refusal
patches. The old broad client run and its prerequisite skips are historical;
they do not substitute for fresh hosted CI and exact-head Linux signoff.

## Next steps

1. Publish the rebased branch to [PR #980](https://github.com/Roasbeef/loom/pull/980)
   and inspect all applicable hosted checks, including advisory macOS logs,
   plus Linux signoff for the exact published head.
2. Merge with a normal merge commit once those checks and independent review
   are complete. The owner authorized rebase and merge on October 16.
   Deployment remains a separate action.

## Integration of strand notes

Main advanced to `d9553247f` while the first signoff waited. Its strand-notes
work is retained; see the [main handoff](https://github.com/Roasbeef/loom/blob/d9553247f/docs/next.md).
The web host consumes both notes facts and queue notices before cleanup. The
shared ordinary step still retains queue notices, while the retaining entry
also transfers notes facts. Fresh tests, review, hosted CI and Linux signoff
are required for this integration; prior-head results cannot authorize merge.
