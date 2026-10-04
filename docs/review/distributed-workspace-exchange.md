# Semantic workspace exchange review

The owner binding commits a distinct Workspace child and its complete canonical
invocation before transport can send it. A retry uses the retained UUID and
compares all original bytes. The executor service commits its first claim before
running the concrete local workspace host, then retains exact encoded completion
before reporting success. The owner validates and commits that completion before
acknowledging its digest. Connection loss changes neither identity nor replay
permission.

Workspace journal format 2 adds a durable seal. Admission and first claims check
that mode within their transactions, including through independent opens.
Queries, completion retention and acknowledgement can reconcile after seal.
Close attempts sealing before cancelling and joining its managed tasks. Failed
encoding, failed persistence and task death after claim remain Unknown. No
cancellation or socket shutdown promises filesystem rollback.

## Component evidence

The root independently passed 152 core tests, 147 storage tests and 35 client
remote tests. The service worker passed all 149 executor tests with real network
permission, including 17 new filesystem/SQLite service tests. Its seal-bypass
mutation fails the independent-open first-claim regression; restoring the source
restores the passing suite. These runs precede the ingress correction below.

`scripts/e2e_remote_workspace.sh` passed with the bundled Gleam 1.19 compiler.
It drives production TLS and chunk framing between an owner custodian and an
executor semantic service, using two real SQLite journals and separate workspace
paths within one emulator. A 500,000-byte write loses its network reply while a
post-write barrier holds completion. A duplicate cannot overwrite a subsequent
external edit. The fixture then retains exact completion, acknowledges it,
reopens the owner custodian under the original identity, reads another chunked
file and refuses a foreign scope. Owner-side canaries remain absent.

`--mutation skip-owner-receipt` exits 1 at the exact owner readback assertion:
the retained child has no completion. It does not reach acknowledgement. An
initial sandboxed attempt instead failed to bind the TLS listener and is not
mutation evidence; the independently permissioned run reaches the intended
assertion. Baseline and mutation command exit codes are captured separately.

## Independent review and correction status

Astra found one reachable P1: a short socket deadline destroyed its sender and
returned the listener slot while the service still retained the queued request.
The service can wait behind ordinary SQLite writer contention longer than the
socket deadline. Repeated connections therefore accumulate mailbox requests
before durable quotas or active-task admission run. The native endpoint has the
same pattern; its stalled Hello usually carries less data but has no finite
pending-count bound.

The correction gives each fixed listener actor custody of at most one service
ask. Both its socket run and the service reply must settle before reuse. A
socket deadline cannot discard the outstanding ask. Individual acceptors and
their subtree are Temporary, so failure cannot recreate capacity while old
mailbox work survives. A late handoff must still pass the NoAsk guard; a second
unresolved handoff retires that credit. This preserves the bound without
assuming cross-sender signal ordering. A downstream journal timeout also
retires the credit; the valid Unknown journal status permits normal reuse.

The independent final executor gate passes 157 tests, including eight real-TLS
ingress regressions. The stalled Submit and Query checks measure exact pending
counts and retained invocation bytes. Other checks kill a socket worker, kill
an acceptor, kill a service, and wait for actual 30-second journal timeouts on
both native and workspace paths. Restoring the previous listener makes both
queue regressions fail at eight asks versus the configured limit of four.
Changing a Temporary child to Permanent fails the no-replacement assertion.
Independent review found no remaining functional issue in the correction.

The joined workspace fixture passes again after the correction. Its final
skipped-receipt control still fails at the intended owner readback assertion.
Client and executor lint pass with no errors; their advisory censuses remain.
The documentation graph passes with no errors. Parrot/sqlc regeneration is
byte-identical to the generated executor bindings used by these tests.

The new PlusCal Ingress model separates queued requests, actual consumption and
delivered replies. Its one- and two-credit safety cases exhaust successfully;
timeout-based credit reuse and acceptor-restart mutations each violate QueueBound
in four states. Positive controls reach recovery and subsequent credit reuse after timeout,
and a crashed owner with pending work. All 33 model-runner cases pass their
specific safety or counterexample criteria. See the model README for bounds and measured counts.
Formal safety does not substitute for real stalled-service regressions or the
implementation's signal-ordering bridge.

## Owner consumer deadline review

The concrete owner consumer passes 11 real-TLS/SQLite tests. The full client
remote suite passes 46 tests with no skips. These include original-identity
retry, exact receipt-before-ACK, executor unavailability, observed Accepted and
Started requests without resubmission, cancellation, changed candidate refusal,
receipt-write refusal and later recovery, oversized input, observer crash, and
initial or post-effect owner contention.

Independent review found that fixed five-second custody waits could escape the
advertised whole-call budget. One managed weft task now bounds all storage,
codec and transport work. Deadline expiry returns ObservationExpired; worker
loss returns ObservationLost. Both carry the original ChildOrigin. Killing the
observer cannot retract a queued custody write, so neither result claims that
execution was refused or grants replay authority.

Relaxing the managed deadline makes the initial-owner regression fail after
the fixed custody waits, while the restored implementation passes.

The post-effect contention test pauses the owner before its receipt recheck.
The filesystem write has already completed, but no receipt or ACK is granted.
Recovery stores the original executor result and acknowledges it without
changing a later independent edit. This test does not claim to inject a lost
SQLite COMMIT acknowledgement.

## Limits

This is not a shipped remote deployment or the separate-host acceptance gate.
Daemon configuration, persisted executor selection, ordinary tool consumers,
physical code-mode compilation/launch, capability forwarding and the complete
LSP host still need production assembly. No component success closes issue #697.

The tests do not inject power loss or an OS-level lost COMMIT acknowledgement.
Logical SQLite quotas do not bound WAL disk or total resident memory. The
embedding host still owns aggregate caller admission, listener/service lifetime,
and separate native retirement witnesses. Gleam opacity does not provide linear
consumption or security against arbitrary trusted Erlang code.
