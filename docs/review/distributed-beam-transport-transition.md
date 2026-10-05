# Trusted executor transport transition

The owner selected TLS BEAM for trusted executors. Commit `3b0372f51` records
the [protocol amendment](../../protocol-change/067-remote-workspace-services.md#addendum-trusted-executor-distribution)
and updates the design, integration guide and work-package plan. Commit
`7439bdef` prevents the executor's Erlang argument environment from becoming
satellite VM arguments. Transport replacement remains in progress.

## Decision and scope

Executors admitted to distribution share the orchestrators' runtime trust
domain. A compromised executor VM or OS account can compromise connected
owners. TLS, hidden nodes and closed application messages do not provide
isolation against that peer. Executor membership remains separate from Raft
voter membership; model-authored satellites remain outside distribution.

The implementation will replace the custom socket transport with one supported
TLS BEAM path. Canonical durable bytes, original identities/deadlines, admission,
receipts and witnessed native retirement remain required. A BEAM send or DOWN
message does not replace those facts. [Issue #825](https://github.com/Roasbeef/loom/issues/825)
tracks explicit secondary targets and artifact handoffs within one workflow;
ordinary multi-peer registration remains part of #697.

## Completed boundary check

The shared `codemode/native_command.node_env` factory excludes every occurrence
of `ERL_AFLAGS`, `ERL_FLAGS` and `ERL_ZFLAGS`. Both local and remote command
construction use the factory. The derived environment allowlist uses the same
filtered values. The existing command arguments still disable distribution
and epmd and supply no node name.

The focused launch suite passed all 26 tests with zero skips and a warning-free
build. It checks the exact filtered environment, duplicate argument variables
and the derived permission request. Codemode lint passed with zero errors and
118 warnings. Documentation checks passed with zero errors and 183 warnings.
The test scratch root was `/private/tmp/lb697`; these launch fixtures use local
Unix sockets and a fake helper, not an actual remote jail.

Earlier attempts remain failures in the verification record: a sandbox denied
dependency resolution, a source-style module name matched no compiled tests,
and a longer scratch path exceeded the macOS Unix-socket limit in one existing
test. The final suite used the compiled module name `codemode@launch_test` and
the short scratch path. No timeout or assertion was removed.

Astra's independent source review of `540e5dc0c..7439bdef` found no confirmed
new issue. It traced the factory to the actual launch environment and checked
the amendment's trust and implementation-status claims. The reviewer did not
rerun the suites.

## Bootstrap and owner-consumer evidence

The bootstrap component now starts independent owner and executor BEAM processes
with private cookie homes, pinned certificates and TLS-only distribution. Three
focused tests pass, including the grouped wrong-certificate, wrong-name,
plaintext, missing-client-certificate and wrong-cookie controls. These are local
two-process tests; they do not establish separate-host routing or satellite
credential exclusion. Commit `2f0028bb` contains the bootstrap component. Independent Sol review
repeated the three controls and found no reachable defect. It qualified the
erpc response timeout: distribution pressure can delay sending, so callers
must own a whole-operation deadline. The public documentation now says so.
An attempted Astra review ended with a service safety flag and supplies no
signoff. Assembled-system review remains open.

The migrated owner-custody suite passes all 25 original controls with no skips.
Each control boots a fresh owner VM through the real membership constructor and
requires an explicit completion witness as well as a zero process exit status.
These controls preserve reservation, cancellation, receipt and recovery behavior;
they deliberately do not claim to exercise an executor connection. The final
fixture sources were compared byte-for-byte with the integration tree before
recording the result.

A real endpoint test exposed a shared-library defect: weft checked a remote
consumer PID with the local-only `is_process_alive` operation. The repair uses
weft's existing signal-delivery primitive. Local already-dead consumers must
still prevent task startup; remote death or disconnection arrives asynchronously
through the monitor. A dependency-overlay test is component evidence until the
reviewed weft revision is pinned in the integration dependency. The rebased commit
`368d01ab` was merged in [weft PR #17](https://github.com/Roasbeef/weft/pull/17)
as `e6b63cfd`.
Both the implementation run and independent Sol replay passed the full
185-test gate, including remote consumer exit, node disconnection and the
already-dead local consumer. After rebasing onto upstream main, the full local gate passes 188 tests.
The integration pins the reviewed Git revision directly in all ten direct
consumers; eleven generated locks resolve it. No local dependency overlay is
needed. The standalone MCP package keeps its external dependency graph; the
assembled client resolves that transitive dependency through its direct pin.

Transport migration must preserve the following existing controls. A fixture
that still constructs the old socket configuration blocks its package gate;
it is not a reason to exclude the fixture from that gate.

| Existing control | Required BEAM replacement | Status |
| --- | --- | --- |
| Owner dispatch and command custody | Real bootstrapped Peer; same 25 original assertions | Focused pass. |
| Compile consumer and joined compiler | Independent executor VM; exact original broker, command and completion custody | Fifteen controls and six compiled mutations pass; independent Sol review completed. Exact outer completion bytes are asserted again. |
| Workspace consumer | Executor-local filesystem and SQLite; owner receipt before ACK; all 11 original controls | Eleven real-peer controls and independent Sol replay pass. |
| Native broker integration | Real helper, output, stdin, receipt and restart behavior | Root script passes with the Git-pinned dependency and real TLS peers. |
| Command-route adversarial transport | Exact reference/generation checks and detached cancellation | Seven preserved controls pass in the root Git-pinned replay. |
| Generation renewal | Quiescent replacement at generation 2 using the original journals and UUIDs | Component verifies ScopeRetirement, native DOWN and actual VM exit before recovery. Daemon assembly remains pending. |

The integration run passes all 68 combined owner, workspace, Compile-consumer
and whole-Compile actor controls with zero skips against the Git-pinned Weft
source. Independent Sol review found that the migrated joined compiler fixture
had omitted its original outer completion byte comparison. The fixture now
compares the owner's persisted completion with the executor's retained bytes.
The passing run includes that assertion.

The root native E2E script builds a fresh helper, compiles the full client package
without warnings and passes its independent owner/executor VM scenario. It
checks generation 1 to 2 against the retained journal, original request identity,
owner restart, output, receipt and refusal behavior. The worker also ran both
named mutation scripts: missing owner receipt and bypassed registration each
failed at the intended assertion. This is a local multi-process component test;
separate-host and registered daemon acceptance remain open.

The first root combined run selected Gleam 1.18.1 from a login shell while its
seed was built with 1.19.0-rc2. Both real compiler controls failed after the
version mismatch forced an offline dependency rebuild. The matching toolchain
passed all 68 controls. A sandboxed attempt also failed because local TLS
listeners were denied; the permissioned run supplies the passing evidence.
Neither failed run is counted as a pass.

The current endpoint binds a registration to one concrete service generation.
It cannot replace that registration in place. Generation renewal therefore needs
host-controlled ingress closure, joined transport and service work, and proof of
native quiescence before replacement. Stopping the endpoint alone is insufficient.
The old generation-1-to-2 recovery assertion remains an acceptance requirement.

## Endpoint credit correspondence

The endpoint correction binds each local service handoff to its original
transport reference. A handoff delayed past transport drain cannot enter service
custody after the same credit is assigned to another request. Five focused tests
pass, including real TLS peers and deterministic stale-handoff injection while
the credit is idle and after reuse. The test checks the entire retained credit
state; it does not infer correctness from a missing output alone.

The new P credit model passes four directed safety cases at 1,000 schedules each,
four exact reachability witnesses, and six compiling mutation controls. Its
monitors check the original reference, service-answer and transport-drain facts,
sticky loss, closed admission and the shared four-data-credit ceiling. These
are bounded model results, not a proof of OTP signal order or native retirement.
Independent Sol review found no confirmed new defect and repeated all five
endpoint tests, all four safety cases and probes, and all six mutation controls.
It also verified the asynchronous Stop qualification below. The root repeated
the five endpoint tests together with the seven command-route controls against
the actual Git dependency; all twelve passed. The full P runner exited zero
with 114 cases/probes and 52 mutation controls. Expected assertion failures in
reachability probes and mutants are checked by the runner; they are not ignored
failures.

Endpoint stop remains asynchronous. Linked child shutdown and consumer monitors
retire its managed runs, but endpoint DOWN alone precedes those completions.
Replacement assembly must obtain an actual join/drain witness before treating
the old transport lifetime as retired. Native retirement is a separate fact.

## Assembled review and known refusal defect

A fresh Astra source review covered bootstrap commit `2f0028bb`, the credit model,
the assembled endpoint and consumers, whole-Compile metadata ordering and the
native restart fixture. It found no additional reachable defect. It verified the
restored exact completion-byte assertion and inspected the root's passing
68-control replay and native E2E log. It did not independently rerun those gates.
The reviewed implementation is committed in `0707dabe`, `94f6834c`, `bf9e10a35`
and `0c1e505fe`; dependency commits `967a17538` and `4621d68ee` pin merged Weft.

One known availability defect remains. `service.command_context` collapses a
missing or conflicting historical resource lookup into `Uncertain`. Whole-Compile
routing treats that answer as uncertain custody, fences admission and retains
its metadata slot; the endpoint also retires its transport credit. A definite
identity refusal therefore prevents later valid work. Genuine journal or ask
uncertainty must keep this conservative behavior, but a known Missing or Conflict
needs a definite refusal after the actual metadata worker drains.

Automatic approval review rejected the proposed native service/interface edit.
The owner has been asked for explicit approval; the native service source remains
unchanged. The required regression must pass a missing/conflicting original
through the actual command endpoint, observe metadata drain and then admit a
separate valid operation. The passing component gates do not close this defect.

## Native fault controls and full executor gate

The TLS BEAM migration preserves all 23 native controls. Seventeen local tests
retain their executable bodies; six transport cases now run real owner and
executor VMs through the production endpoint. All 77 assertions across five
transport cases remain. The saturation case preserves ten native and outcome
assertions while replacing fourteen socket-administration assertions with fixed
credit, bootstrap and joined-role controls. No test was skipped or deleted.

The test fault actor first calls the real native service, then holds, drops or
rejects its actual answer. A fixed journal observer forwards only Inspect,
ReadPayload and Release to the original executor journal, preserving the reply
subject. It neither reopens SQLite nor manufactures evidence. The test-only
Erlang adapter changes private reply doors; it adds no production replacement API.

The exact three-file focused replay passes all 23 tests with zero skips.
A fresh Astra review independently checked the complete test-name set, body and
assertion parity, actual-answer faults, original journal forwarding and bounded
role cleanup. It found no actionable defect. The root then ran the full
`make check-executor` gate against the assembled Git-pinned dependency: all 299
tests pass, zero skips, command exit 0. Its test runner completed in 99.65 seconds.
The migration does not establish registered host lifecycle or separate-host
acceptance; old socket tests still cover components awaiting replacement.

## Workspace effects and pending caller loss

Commit `b573053cd` moves the workspace E2E fixture onto independent owner and
executor OS processes using real TLS BEAM membership and endpoint exchange.
The integration-tree `scripts/e2e_remote_workspace.sh` passes with command exit 0;
its runtime wrapper completed in 8.74 seconds after warning-free client build.
The parent requires both role exits, the original completion stdout and explicit
owner/executor completion markers.

The fixture suspends the concrete semantic service, observes the exact canonical
Submit and original child UUID in its mailbox, then waits for the endpoint's own
caller deadline and join. The same full message and assigned credit must remain
before service resume. A narrow test-only binding to stock `process_info/2`
supplies that observation. It adds no production hook or custom Erlang code.
This covers actual pending caller loss; it does not claim a literal TLS packet
was dropped.

All fifteen retained custody/effect helpers are byte-identical. The original
38 assertions retain explicit counterparts, including payloads above 256 KiB,
physical write before durable completion, Unknown during the write barrier,
retry without overwriting a later editor change, exact owner receipt before ACK,
SQLite custodian reopen, complete large Read and wrong-scope refusal.
The custodian reopen is not an owner OS-process restart.

Astra's first review found that the initial migration canceled an observer only
after its exchange had returned. The corrected queued-Submit control closes that
gap. Independent final replay passes in 9.359 seconds. The receipt mutation fails
at the original `persist_before_ack` comparison: the actual SQLite receipt is
None instead of Some(result). Its later executor barrier timeout is a consequence,
not the mutation witness. No outstanding actionable finding remains.

The fixture verifies semantic closure, journal sealing and actual native
ScopeRetirement followed by native Normal DOWN before journal release. This
covers its empty native pool, not the proposed production host-close correction.
Registered daemon and separate-host acceptance remain open.

## Repository milestone gate

The assembled milestone `make check` invocation passed every Gleam and
JavaScript package gate, then exited 2 in the Go suite. Its single failing test,
`TestSeatbeltJailedPathFindsHomebrewTools`, resolved `rg` to the Codex executable
under `/Applications`. The test jail permits the system tool roots, including
`/opt/homebrew`, but cannot execute that application path.

The complete Go suite then passed with the existing Homebrew `rg` selected on
PATH. The replay retained Gleam 1.19.0-rc2 from the installed Loom toolchain; no
source, test or sandbox policy was changed. The remaining full house lint also
passed, with zero errors and 2,050 warnings. These component results do not turn
the original failed aggregate invocation into a passing one.

The package run reported 17 explicit SKIP notices: three Linux `/proc` controls,
thirteen shipped-server fixture notices, and one unavailable rust-analyzer.
Those paths still need their actual prerequisites. The final candidate requires
its fresh repository gate and Linux/shipped acceptance before merge readiness.

## Real language-server baseline

Independent physical-host verification ran the six existing
`conformance@lsp_e2e_test` controls with real Gleam and Go servers. The first
invocation exited 1: five passed, none skipped, and SQL-Go failed to initialize
its build cache. The verification runner had set a private `GOCACHE`; the SQL-Go
fixture does not forward that variable, so its allowed cache path differed from
the default path used by its child. The ordinary Go fixture forwards it and
passed. No product or sandbox policy was changed.

Replaying only `lsp_sql_gopls_end_to_end_test_` with the fixture's default cache
contract passed, command exit 0, with zero prerequisite skips. Its SQL result
retained two Greet references, zero Lonely references, the unused Lonely symbol
and ten facts. The evidence is five original passes plus one corrected replay;
the initial aggregate remains a failed invocation.

The private verification worktree used the actual Git-pinned Weft source,
Gleam 1.19.0-rc2 and OTP 29. Twelve relevant host/control source files were
compared byte-for-byte against the integration tree before execution. The native
helper enforced Seatbelt filesystem/network and file/CPU limits under the test's
explicit BestEffort demand. macOS address-space, process-count and process-lifetime
limitations remained visible. This establishes existing local physical-server
behavior, not remote owner clearance, production registration or separate-host
acceptance. No new fixture or production source was added for this verification.

## Remaining acceptance

Independent review of the assembled bootstrap, endpoint, whole-Compile actor,
owner consumers and native restart fixture found no additional reachable defect.
It confirmed the known historical native lookup issue described above. The full
client gate passes 2,847 tests with fifteen explicit optional SKIP notices
(Linux `/proc` coverage, shipped-server fixtures and unavailable rust-analyzer). Registered daemon
assembly remains pending. Scoped shutdown must fence a registration before its
services stop, preserve sibling capacity, and retain original transport and
native drain witnesses. Executor assembly must still exclude credential files
and inherited descriptors from satellites, and test actual distribution-disabled
execution. The environment test alone establishes none of those properties.

Existing framed-TLS component tests remain evidence for the old adapter only.
Separate-host ordinary tools, Compile/Launch, owner capabilities and LSP still
gate the product. Formal-model correspondence must be updated against the final
endpoint, not inferred from an unchanged abstract model.
