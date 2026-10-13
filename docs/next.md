# Current handoff

Baselined October 13, 2026 against `3b0203f80` on `web/queue-controls`,
starting from main `dc70d25d4`. This edition covers held-message Edit and
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
Protocol-change/087 records the new command and `removed` acknowledgement.
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

The complete web package gate passed 1,003 tests and the shared-session gate
passed all 482, each with exit 0. Browser asset generation and its digest checks
passed. House lint and documentation checks are recorded separately on the PR.
Gateway and protocol regressions passed for author/observer refusal, stale
revisions, wrong strand, equal-text neighbors, repeated removal and admission
before removal. The broad client run is still in progress at this checkpoint;
its result belongs on the PR. It has reported prerequisite code-mode skips
because this checkout has no prepared seed. No tests were removed or skipped
by the implementation.

An isolated browser loaded the actual Lustre 5.7.1 runtime, generated stylesheet,
and mount/diff JSON produced from the real queue row views. Multiline browser
text, cursor position and the exact textarea node survived a patch that removed
a neighbor and changed the server's submitted text, followed by a refusal
patch. The transport was simulated; this did not exercise the installed daemon
or a live provider. The gateway regressions exercise real runtime admission.
The independent review findings were fixed and rechecked with no remaining
correctness finding.

## Next steps

1. Publish the branch as a PR and record the broad client result and exact head.
   Exit: affected-package gates and the browser evidence are linked to that PR,
   with prerequisite skips explicit.
2. Inspect hosted CI and required Linux signoff for the published head.
   Exit: required checks attest to that head; local tests do not substitute for
   release or deployment signoff.
3. Merge and update the running daemon only with the owner's authorization.
   Exit: the deployed operator page offers Edit and Remove on its own held
   messages, and edits preserve attachments and order.

## Rebase in progress

This branch is being rebased on main `6430703a9`. The earlier validation above
is historical evidence, not validation of the rebased head. Current main's
TLS encoding, provider diagnostics, and prior rulings remain in the
[main handoff](https://github.com/Roasbeef/loom/blob/6430703a9/docs/next.md).
The final queue handoff will be rebaselined after current-head validation.
