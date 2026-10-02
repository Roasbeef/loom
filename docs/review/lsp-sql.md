# SQL LSP observation review

This review covers `codex/lsp-sql`, based on `7d37ec86f`, and the supporting
native SQLite and companion binding changes on October 1, 2026. The accepted
contract is [protocol 062](../../protocol-change/062-lsp-sql-observations.md).

## Independent pass and corrections

One independent adversarial pass traced default host routing, collection,
satellite SQL and cancellation custody. It included tracked and untracked
implementation files, not only the branch's unchanged HEAD. The reviewer
reproduced both collection findings against the compiled production manager
and the existing fake-server seam, without editing source.

| Finding | Reachable consequence | Correction and regression |
| --- | --- | --- |
| Source preflight reused admission from before server startup. | Replacing a requested source with a protected-path symlink during startup caused an unjailed read into host memory. Collection later refused publication; model exfiltration was not demonstrated. | Re-admit immediately before the size preflight and require the same canonical path. The startup-swap regression uses oversized protected text and requires `Changed`, rather than the `LimitExceeded` that an unauthorized read would produce; no document is opened. |
| Path-only seed resolution omitted strict coordinate validation. | A one-line source and a malformed selection position produced a references request and an accepted target at line 1000 with empty text. | Validate resolver symbols against retained content before refining a seed. The malformed-seed regression requires refusal and no references request. |

The reviewer also identified a test-only generation-prefix mismatch in the
new E2E template. The assertion now uses the actual `sha256-` content-address
prefix. The complete collection suite passes fifteen tests after both fixes.

The native review found no further reachable authorization bypass, SQLite
error-pointer lifetime defect or dropped owner-death cancellation path. It
checked callback lifetime through statement finalization and independently
reran the eleven new native test functions, all passing. The native suite has
forty-six tests, including the earlier statement-retirement regressions.

The same-shape review also covered old open-document resynchronization. Those
reads now re-admit the old spelling, close a withheld document and never send
protected text to the server. Its regression is part of the collection suite.

## Validation boundary

Focused checks have passed for typed cap decoding, capture routing, disposable
and resident host cancellation, configured-only client plumbing, LSP actor
state metadata and the full existing LSP suite. Both new real-server SQL E2E
fixtures compile. The complete program in the design and usage guides compiles
unchanged with warnings treated as errors.

Before the loader correction, the native checkout, a cold declared-source
bundle and a cold unpack of the Hex payload each passed forty-six tests.
The companion binding passes
twenty-one tests under stock Gleam 1.18.1 using a temporary local native wrapper.
That wrapper proves the implementation, not the published package graph.

The first real SQL E2E run exposed missing native artifact custody: the builder
flattened BEAMs but omitted SQLite's library, and the loader's fallback depended
on the working directory. The fixed library now joins the artifact read root
and fingerprint. Module-relative fallback preserves normal OTP `priv` loading.
Ten build tests cover native-byte changes, removal and exclusion of unrelated
libraries; a fresh-VM native loader regression brings the full native suite to
forty-seven passing tests, including a cold unpack of the final Hex payload.

A narrow independent follow-up reviewed this packaging delta and both earlier
collection fixes with no additional findings. It did not rerun tests. Both real
jailed Gleam and Go SQL cases then passed joins, counts, anti-joins, typed decoder
failure, DELETE refusal, invalid server scope and unchanged metadata. These runs
used a native wrapper only inside the ignored experimental build seed. The
matching stock-Gleam code-mode suite passed all 340 tests with zero skips.
An earlier mixed-compiler run failed only the byte-identical seed check because
the seed used 1.18.1 and the runtime compiler used 1.19.0-rc2; no gate was removed.

Native publication, a cold resolved stock-Gleam graph, the final offline seed,
the aggregate gate and hosted Linux/macOS verification remain pending. Existing
macOS resource/process-lifecycle degradation was reported rather than weakened.
Standard LSP still does not offer a project-wide transaction: unseen dependency
changes are outside the finite checked interval guarantee.

## Fresh review after PR creation

On October 2, [Loom PR #693](https://github.com/Roasbeef/loom/pull/693) opened
as a draft before the requested fresh Astra review at high reasoning effort.
The review pinned Loom `7d37ec86f..f6ba5337d`, native
`e38d89bb..adf8d65a`, and companion `ec867545..ab7932e0`.
It found no new confirmed defect and requested no implementation changes.

The reviewer traced source admission and coordinate conversion, default host
and seam routing, native authorization and limits, cancellation ownership,
and native artifact custody. It independently reran all fifteen collector
tests and twelve native query, retirement and flattened-loader tests. Both
runs exited zero using existing compiled artifacts. It did not rebuild a
cold seed or repeat the reported real jailed E2E runs.

The disposition is suitable to remain a draft with no new code-review
blocker. Dependency publication approval, exact native and companion pins,
resolved manifests, a cold published-package seed, aggregate verification
and Linux/macOS signoff remain required. The experimental wrapper does not
establish that shipping dependency path.

## Capability-only LSP follow-up

On October 2, the owner authorized removing all seven default top-level
`lsp_*` registrations while retaining `cap/lsp`, `cap/lsp_sql` and automatic
write diagnostics. The requested Astra high follow-up reviewed
`055676ae8..2b5941df10945e8e2bee070271d015512045dc6c` and found no new
confirmed defect. It requested no implementation changes.

The reviewer traced the default registration, profile-note discovery and
closed-seam admission, the separate SQL import/service requirement, rename
write authority and shared base checks, and the migrated acceptance cases.
Rename still inherits the outer tool's `Never` replay and `Exclusive`
execution. Separate preview and apply calls are model guidance, not a new
authorization mechanism. Saved session pins are not rewritten.

The reviewer independently reran 54 code-mode tool tests, 12 client plumbing
tests and 24 default-prompt tests from existing compiled artifacts, each with
exit zero. It inspected the recorded six-generator real-server run and
confirmed all named generators ran with no prerequisite skips; it did not
repeat that run. The root's full tools suite passed 610 tests, the prompt
suite passed 102, and client plumbing, contributions and system-prompt suites
passed 12, 16 and 46 tests. Format, scoped lint, prelude and documentation
gates exited zero, with existing non-gating warnings.

All six real-server LSP generators passed after the legacy calls moved to
compiled capability programs. They retain anchored references, preview
without writes, fresh multi-file apply and diagnostics, stale refusal, Go
queries and both SQL cases. They also cover sibling-package queries with
withheld source context and check that provider requests contain no
`lsp_*` tools. These runs use the same experimental seed; they do not prove
the pending shipping dependency graph. The publication, pin, cold-seed,
aggregate-gate and platform-signoff requirements remain open, so the PR
remains draft with no new review blocker for this delta.
