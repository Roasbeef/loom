# Caller-owned messaging inspection and steering review

## Scope and pins

The implementation was rebased without conflicts onto `e79f722de`. Final
source head was `54aeb10b4fe63feed4deca5cb01ba5b49124b634`; documentation follows
in a separate commit. The range-diff preserved the reviewed machine, runtime,
API, prelude, and live-test changes. The bounded SQLite cursor correction was
folded into the register-query dependency commit.

Sol independently reviewed the API draft at `c7883d696`, including pending
membership, transcript ownership, consumption races, receipt authorization,
cursor progress, bounds, and default host exposure. It reported no actionable
findings. That reader implemented the earlier fairness change but did not
implement the API it reviewed.

Astra reviewed fairness, the API, and the supporting storage seam, then pinned
its final source review to `54aeb10b4fe63feed4deca5cb01ba5b49124b634` with no
remaining findings. It confirmed committed terminal-cleanup waiting, the real
jailed capability proof, and the range-diff preservation. It did not rerun the
broad integration gate.

## Findings and dispositions

The initial receipt implementation captured all receipt bodies before paging.
A small query could therefore fail the snapshot cell or byte budget as history
grew. This reachable finding was fixed with internal `snapshot.KeyPage`
discovery in the existing backend transaction before selected bodies are
copied. It changes no frozen Storage interface or message transport.

The first SQLite page query scanned from the prefix lower bound and filtered
the exclusive cursor afterward. A late one-row query over twenty thousand
records took 100007 VM steps versus 71 for the first page. The corrected query
seeks from the indexed maximum of prefix and cursor, then excludes the cursor
itself. The standard-library SQLite regression and twenty-four snapshot tests
passed. Captured cells remain unordered; the receipt caller explicitly sorts
keys before taking the window and filtering recipient ownership.

The original machine assertions checked only `ProviderRequest.context.trigger`.
The runtime regression now admits real local and remote sends while a tool is
blocked and asserts that the very next production GenerationRequest includes
both exact bodies and the tool result, with no intermediate request. Whole
parallel batches retain source-ordered result materialization and custody.

The abort recovery test initially read immediately after asynchronous abort
admission. It now awaits the operation's durable terminal result before reading
the unchanged remote receipt. Local aborted pending payloads still have their
existing deletion lifecycle; no new retention was authorized or implemented.

## Validation and limits

The following commands passed by their own exit status before the rebase.
The parent must run its independent full gate on the final rebased head.

- Machine focused suite: ninety-three tests.
- Client steering delivery regression: exact next-request local and remote body.
- Client message inspection suite: six tests, including twenty-five pending
  inputs over three pages, foreign IDs, consumption between captures, remote
  abort recovery, aggregate receipt budgets, and production-router identity.
- Client code-mode wiring suite: seventy-two tests. The outer filesystem
  sandbox initially denied four existing temporary fixture writes; the same
  authorized suite passed outside that outer sandbox.
- Cap peer marshalling and tools model-visible discovery regressions passed.
- Client lint reported zero errors; format, generated prelude, diff checks,
  and documentation checks passed with existing non-gating warnings.
- Real jailed inspection ran with the installed compiler directory on PATH:
  `bash scripts/test.sh client --match caller_owned_messages_cross`.
  `/private/tmp/loom-cpu-20260929/message-live-channel.log` records the actual
  test at 0.740 seconds and wrapper exit zero, with no prerequisite skip.

The real program reads pending, exact input, transcript history, recipient
history, and exact remote receipt through the capability socket. Its unlinked
sender query is refused. The production wiring suite separately proves all
peer signatures are offered on both default program seams. The temporary
compiler shim could not be looked up inside its declared jail mounts; using
the actual installed compiler directory corrected the test environment.

The large receipt test checks bounded capture and a foreign-only cursor page,
then seeks near the owned record. It does not traverse all 1050 rows through
successive API cursors; backend tests cover exclusive ordering and deletion.
Receipt cursors are hash-key order, not an incremental arrival watermark.
Responses beyond the documented byte ceiling fail rather than truncate.

A baseline hosted macOS worktree-diff ancestor-read failure was independently
confirmed on main and the unrelated CPU PR. It remains separate from focused
local real-jail success and does not establish fully green hosted CI.
