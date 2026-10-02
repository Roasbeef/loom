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

The native checkout, a cold declared-source bundle and a cold unpack of the
actual Hex payload each pass forty-six tests. The companion binding passes
twenty-one tests under stock Gleam 1.18.1 using a temporary local native wrapper.
That wrapper proves the implementation, not the published package graph.

Native publication, a cold resolved stock-Gleam graph, the refreshed offline
seed, actual jailed E2E, the aggregate gate and hosted Linux/macOS verification
remain pending. Standard LSP still does not offer a project-wide transaction:
unseen dependency changes are outside the finite checked interval guarantee.
