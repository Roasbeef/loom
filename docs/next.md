# Current handoff

Baselined October 16, 2026 against main `1536934a4` and the rebased `/btw`
branch for PR #981. The earlier instruction to merge `207c6571b` is obsolete:
the owner requested a rebase and fresh UI screenshots after main advanced.
`207c6571b` passed hosted CI run 38558170965 and signed Gilgamesh signoff.
The first October 16 rebase, `bbeb4b61c`, also passed all 18 executed CI jobs
(run 38935120272), both actual macOS advisory shards, and strict Gilgamesh
signoff in 1809 seconds (driver 1815 seconds). Those results do not validate
the next rebase: #990 merged just as the first rebase became green.

## Accepted side-query design

Protocol-change/087 specifies frozen effective dispatched context, bounded
follow-ups, explicit refresh and no tool execution in TUI and web. Settled
text-only answers may extend a base; streaming fragments and pending tool
exchanges never do. Histories remain private, ephemeral attachment state.
Side requests retain provider settings and the frozen Anthropic cache endpoint.
Live Anthropic cache savings remain unmeasured until credits are configured.

The review fixes retain capacity after lost drain proof, suppress expired side
poll deadlines while the command lane is busy, share TUI paint/scroll/copy
geometry, and wrap side text at the actual docked width. Three review rounds
and cold slice reviews approved the earlier implementation. See
[the triage](review/btw-2026-10-13-triage.md). UX follow-ups are #983; integrated
fallback-capture coverage is #984.

## Rebase boundaries

Current main includes per-strand throughput, catalogue completion, bounded
native-test concurrency, provider disconnect diagnostics and keepalives,
preparation reuse, process identity and UTF-8 TLS options encoding. Preserve
those paths. The web component conflict was additive: both completion choices
and the side-state accessor remain. Package docs retain both features.
The ordinary Linux deployment skip uses main's single declaration, with its
separate delegated enforcement test and empty skip allowance unchanged.

For the upstream performance and TLS investigations, consult main's
[previous handoff](https://github.com/Roasbeef/loom/blob/6430703a98c6371020c09aedb5b067e8c5c570aa/docs/next.md)
and the linked review reports. CPU, cumulative allocation, retained memory and
RSS are separate claims. This branch neither installs nor restarts the user's
daemon.

## Strand-notes integration

Main `d9553247f` adds #990's bounded read-only strand-notes browser. Both the
surface-custody equivalence test and the side-action refusal regression remain.
Web components retain notes adoption and side polling; package docs preserve
both boundaries. Production source merged without textual conflict. The generated
web assets are rebuilt from the combined source.

Fresh TUI/web captures from `bbeb4b61c` are posted in
[the PR comment](https://github.com/Roasbeef/loom/pull/981#issuecomment-6220628018),
outside Git history. Both UIs answered side questions during main streaming;
raw requests and the two main-only durable entries prove context and history
isolation. Repeat UI smoke checks after this notes integration.

## Queue-control integration

Main advanced through #980 to `1536934a4` while the notes-integrated head
finished validation. Retain both `remove_queued_input` and `btw` in auxiliary
command decoding, queue-removal authority and side-observer denial tests, and
both queue/notes custody and side-refusal regressions. The shared host cleanup
retains its current queue-aware rules; private side state remains separate.
Generated assets are rebuilt from the combined source.

At `2b42233a8`, strict Linux signoff passed all six lanes, release/update and
the strict skip census in 1799 seconds (driver 1804 seconds). Linux CI and the
second macOS advisory shard passed. The macOS E2E job hit the unchanged
code-mode cancellation fixture's 500 ms invocation deadline. Five exact local
attempts and the full local code-mode E2E gate (410 tests) passed, supporting a
suspected timing flake. No test was changed and no hosted retry was issued;
the run was cancelled as superseded when #980 created new conflicts.

[Refreshed captures](https://github.com/Roasbeef/loom/pull/981#issuecomment-6221718804)
show both real UIs and Notes beside the private web side answer on `2b42233a8`.
Both private requests retained main context and their question/answer text was
absent from durable entries. They are prior-head evidence for the next rebase.

## Verification and next steps

Three separate total decoders read `deployment.status` (`tui/deployment_view`,
`web_view/machines` and `ledger_control.member_view`); one in a pure package could
replace them.

Earlier personal E2E drove both real UIs during a continuing main stream,
proved frozen follow-ups and refresh through captured requests, checked private
attachment histories and main-only durable entries, and verified cancellation,
tool refusal, long-answer paging and OSC52 copying. Rebuild and repeat the UI
checks for this rebase; post screenshots as PR attachments, outside Git history.

Run affected package and static gates, hosted CI, and exact-head strict Linux
signoff through the confirmed `gilgamesh-signoff` alias. Its `obelisk` hostname
and separate account are intentional. The owner authorizes merge once all these
gates are green on the published head; prior-head green results never substitute.
