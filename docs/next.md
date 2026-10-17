# Current handoff

## First-session startup — October 17

Local TUI launches now resolve the daemon while the original terminal discovers
its workspace and constructs its model. Weft owns the worker; joining consumes
final accounting before control adoption. Terminal death cancels discovery and
retires even an unclaimed control handle. Worker/account loss remains fatal so
an unpublished handle cannot leak. Other launch modes keep their order.

The independent three-pair smoke repeat measured roughly 50 ms faster warm
attachment and 45 ms faster cold autostart in paired medians. The wider
seven-pair/two-configuration series was noisy; 32-model cold startup remains
inconclusive. These are selected saved-session journeys with explicit
best-effort enforcement, not picker-to-New or deployment guarantees. All 80
trials accepted a durable PTY user turn and shut down normally; all 120 native
identities retired. The [raw async measurements and artifact audit](review/async-startup-2026-10-17.json)
retain both series. The server is identical on both sides; 826 other common
client BEAM modules match byte for byte.

The full TUI gate passed 1,450 tests and the real-control TUI fixture passed all
20 tests. Formatting, lint, docs, release smoke and deliberate fatal/accounting
mutations passed. Final-head hosted CI remains required before merge.

The [first-session startup note](design-notes/first-session-startup.md) records
the release benchmarks, raw measurement data and validation limits. The preceding
wave batches 25 measured Gleam modules after domain configuration validation
and before resource acquisition. OTP owns its existing code cache; a rejected
hint keeps ordinary demand loading. There is no eager daemon warmup, native
shim, custom once flag or new configuration switch. Three retained callbacks
also capture only their required Settings fields, preserving restart custody.

Against the frozen initial startup wave, nine alternating production pairs
with a 32-model synthetic configuration reduced first residency 378 → 342 ms
(all nine faster), later residency 100 → 91 ms, and cold daemon through the
real TUI composer 1414 → 1357 ms (seven of nine faster). Ten-session peak RSS
fell 284 → 237 MiB and sampled growth 18.44 → 14.37 MiB in that same series.
These measurements select explicit best-effort enforcement; they do not
establish full-enforcement deployment latency or exact reachable memory.
That earlier comparison used an unchanged TUI artifact and measures no separate
client-startup improvement. The async client comparison above is separate.

The earlier wave shares one TOML document within each load, preserving file
rereads, secret rotation, strict validation and error precedence. Its concurrent
OTP application startup retains dependency order, rollback, native identity and
UTF-8 diagnostics; an isolated matched comparison reduced daemon readiness
465 → 438 ms. The decoder-only reduction is about 91%. Wider daemon and TUI
module inventories were rejected after mixed latency and higher RSS.

The benchmark distinguishes create reply, residency, first-domain startup and
the real attached composer. Use alternating `--against` release comparisons;
old JSON without compatible RSS/workload/enforcement provenance is refused.
The initial revision passed all hosted Linux/macOS checks. Local follow-up
validation passed 159 tests and failed one existing jailed-listing fixture
because this container cannot create its bwrap namespace. Formatting, lint,
documentation, actual release inventory/native-initialization checks and
deliberate loader mutations passed. The earlier local full-client run also hit
the satellite endpoint-readiness fixture. Read the note before claiming a full
local gate or deployment speedup. No operator daemon was installed or restarted.

The separate [request gzip experiment PR](https://github.com/Roasbeef/loom/pull/1000)
contains both real TUI/browser experiments and native transport measurements;
it changes no production request-encoding default.

## Previous handoff

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

Earlier personal E2E drove both real UIs during a continuing main stream,
proved frozen follow-ups and refresh through captured requests, checked private
attachment histories and main-only durable entries, and verified cancellation,
tool refusal, long-answer paging and OSC52 copying. Rebuild and repeat the UI
checks for this rebase; post screenshots as PR attachments, outside Git history.

Run affected package and static gates, hosted CI, and exact-head strict Linux
signoff through the confirmed `gilgamesh-signoff` alias. Its `obelisk` hostname
and separate account are intentional. The owner authorizes merge once all these
gates are green on the published head; prior-head green results never substitute.

## Memory as recall

[The memory page](architecture/memory.md) is the account of how it works and
[the decision record](design-notes/memory-recall.md) is the reason.

**What landed.** Memory is now recall, not a digest. `history_search` is the
memory tool: it takes `syntax` (`words` with prefix terms and `OR`, or `raw`),
`kind`, `before` and, for `read`, `around`, and every hit carries its kind and
date. `remember` writes typed notes (`title`, `description`, `kind`, `note`),
indexes them under kind `note`, and rebuilds the 1 KiB `loom-memory.notes`
index that each run carries by default (`[memory] inject = "notes"`), and a
session open rebuilds that index from the store without taking the lease. The
digest and the distillation pass that produced it were removed; `distill =
"off"` still parses and does nothing, and an old store's leftover rows and
digest file are not read or deleted. `propose` queues a standing rule and
`loom-rules.md` changes only when the daemon's owner approves it
(protocol-change/086); the prompt carries the file last, in an
`origin=approved-proposal` fence, and only new sessions read it. The
transcript draws a search as a step with its hits, and the owner reviews
proposals with `Alt+p` in the terminal or in the Session pane on the web page.

**Left open on purpose.**

- A proposal kind that edits configuration, and one that targets the global
  `AGENTS.md`. Both stay out until there is an edit door for them.
- Owner-only admission of the web proposals pane at the operator socket, by
  teaching `ui_socket.owner_accepts` the path. Today the socket admits it like
  remembered permissions, and the daemon is the gate.
- Notes search on the standalone host. Only the daemon adds the memory store
  to the history owner's sources.
- A logger with session context for `memory.search_called`. `serve` calls
  `history.seam` and `history.seam_for`, which log through the Erlang logger,
  where `seam_with_logger` and `seam_for_with_logger` already take one.
- A guard for the 512-source bound. The memory store is one source in the
  list, so a domain with 512 saved sessions and a store refuses shared history.

The proposal queue is the domain's, in `loom-memory.db`, and every write
holds the store's writer lease, so a review in any session shows every
proposal and two approvals cannot erase each other. A `propose` or a decision
that finds the lease held is answered busy and is not retried. The notes index
is rebuilt from the store when a session opens. The usage counter for notes is `note_hits` on
`memory.search_called`; `memory.proposal` records each proposal transition.

**The first number to watch.** Whether any of the owner's eight existing notes
is ever returned by a search. Read `note_hits` on `memory.search_called` over
the first two weeks; zero means the index and the search are not earning their
cost. The recall test's figures (6 of 30 paraphrase wordings found by exact
quoted words, 16 of 30 by prefix terms with `OR`) come from a synthetic corpus
and say nothing about real use.

## PR #955 rebase and focused review

PR #955 was rebased onto main `877e05f56270fada0392ad7b1f252462230ebfa3`
on October 16, 2026. The replay preserves remote-child drain and release,
held-input withdrawal, Notes, completion and private side queries. Side-query
accounting now calls `auxiliary.record_request`, and the lease-free register
reader uses main's decode cache for the duration of its connection. The Memory
overview is implemented in both hosts; the earlier open-item list incorrectly
left it pending.

The focused independent review found one P2 defect in
`memory.rebuild_notes_index`: its lease-free read could publish an old snapshot
after a concurrent `remember` had committed and published a newer index. The
fix takes the existing memory-store writer lease before reading and retains
it through sidecar publication. A held lease leaves the index alone and logs
an in-band refusal without failing session startup. Overview reads remain
lease-free. Regressions cover writer exclusion, preservation of newer notes,
absent-store behavior and cleanup after a publication failure.

The rebased client builds with warnings treated as errors. Storage (299 tests),
events (56), focused memory (71), proposals (53), side queries (6) and daemon
manager (50) suites pass.
Formatting, documentation, generated web assets, prelude and lint gates pass.
The original PR's Linux signoff predates this rebase. Full hosted CI, fresh
Linux signoff and live UI validation are still required before merge.

The follow-up fix passes 73 focused memory tests, including real server
startup while another memory writer holds the lease. The exclusion regression
fails against the original implementation and passes with the fix. A fresh
Astra review of `36a465c9e` against base `877e05f56` found no actionable
findings in the fix or the broader targeted recall/proposal review. Proposal
(53 tests) and daemon-manager (50 tests) regressions also pass on that source.
The review inspected the test evidence without independently rerunning it;
full hosted CI, Linux signoff and live UI validation remain pending.

Hosted run `39003421131` passed every Linux test job but its fan-in rejected
inherited enforcement skips for deployment-status scope and remote subagents.
The ordinary-runner census now declares those exact prerequisites. The
existing strict delegated deployment step covers both scope and up/down;
a new strict delegated subagent step executes the child lifecycle fixture
with an empty skip allowance and retains its log. No fixture assertion or
skip condition changed. The recorded Linux bucket logs pass the repaired
census, and a delegated subagent skip is still rejected.

Strict signoff on `9810ad1db` passed all six lanes, release/update and the
skip census in 1882 seconds (container driver 1887 seconds). Its client log
shows both deployment scenarios and the remote-subagent fixture executed.
Those results are prior-head evidence: this CI integration must receive
fresh hosted CI and Linux signoff before merge.

The next hosted client run and strict Linux signoff on `e962d3e21` failed
one inherited delegate-retention assertion: the test accepted `Stopping`
as drained because it waited only for non-residency. The manager correctly
retains that slot until its normal custody witness exits, so an immediate
second sweep can delete zero rows. The regression now waits for `Saved`,
which proves that the slot has been removed, before demanding one deletion.
The deletion-count and catalogue assertions and the existing two-second
observation bound remain unchanged. All 23 delegate-host tests and five
focused runs pass locally. Fresh validation is required on this test repair.
