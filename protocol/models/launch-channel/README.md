# Foreground whole Launch and consumed duplex channel

Status: bounded abstract model and source correspondence for independent review.
The production integration remains separately owned and unverified by this model.
Model SHA-256: `324fcaa3a35221f25bbdd78e021bf603e5af1d6dddf07fc4ef742638ff1d07cd`.

The authority is the accepted `docs/design-notes/distributed-launch-channel.md`
and the Foreground Launch channel implementation contract appended to protocol
067 in the integration checkout. This note restates their model obligations; it
introduces no wire record or public runtime interface. Its isolated checkout
base is `27cdc21c96ea3577657722f669b6375185281f91`. Directory deletion additionally
follows the accepted owner custody correction: a known outcome alone is not safe
cleanup. The freeze packet records exact authority and source hashes.

The concrete counterpart is the final frozen `codemode/run_channel.gleam` API
at SHA-256 `6e161174bc6987462172586aa46d6cad60a85ae7c8092110fde49fca080f5b23`.
The independent review checked its directional reservation, exact consumption,
Final and retirement operations against this model. Connected installation,
actual socket work, serialized copy validation, host slot transitions and cleanup
propagation still need correspondence against the finished production path.

The initial evidence packet dated 2026-10-05 used the earlier API skeleton at
SHA-256 `7b2d4fa197d78410d5c16006d2cdca3222d644a809129d7faf67a3509f09cab4`
and API brief `b699c730cdc8b6894193c7a1bded63124c1a4b2d4b1f03fedc166410d1e9dc4d`.
Those hashes preserve that packet's scope; the mapping below names the final
frozen API. Neither comparison proves an implementation refinement.

## Actors, identities and observations

LaunchChannel is the original resource owner and its serialized direction state.
Scenario schedules control and recipient actions through commands and waits for
actual returned decisions. ChannelSafety reconstructs original identities,
held windows, byte charges, invocation slots and consumption from emitted effects.
ChannelReachability requires those effect histories plus refusal observations;
reaching the final script index alone does not satisfy a probe.

Remote identity is the original Launch service key, scope, transport generation
and live incarnation. LocalBinding has service zero and cannot substitute for
remote authority. P integer atoms stand for already validated original facts;
cryptography, TLS admission and opaque-reference minting are outside this model.
The returned Applied/Refused enum describes a guarded model command only. Refused
is not the runtime LaunchRefused witness of no native dispatch. Whole-launch
preparation/refusal/unknown classification remains an existing custody-model and
runtime obligation, rather than being fabricated by this direction reducer.
A frame reference adds direction and a positive monotonically increasing sequence.
The model calls ToHost `ToOwner` and ToNode `ToSocket` to name the actual consumers.

| State | Meaning |
|---|---|
| PreparedPaused / PreparedWindow | Original connection exists, but the host has not installed custody or activated delivery. |
| Active / Available | Custody was installed once and this direction can reserve one frame. |
| Reserved | Length and wire bytes were charged; complete delivery has not occurred. |
| Pending | One complete frame is delivered; actual consumption and applied ACK are separate observations. |
| Terminating / Finished | A terminal was validated and Final consumption grants no next frame. |
| Closing / WindowRetired | Cancellation, malformed input, exhaustion or owner loss fenced original windows without refund. |
| Retired | Original closure, both joins, native retirement and resource release discharged the live entry. Historical evidence remains. |

SocketConsume means the original socket writer consumed the whole frame. It does
not mean the satellite application processed it. ChunkAck means relay receipt
only. HostAdmit means actual semantic admission into bounded call, immediate or
terminal state; it is a different observation from relay reassembly. AckSent is
nonblocking notification to the original producer; ReceiveAck applies it. Close
can interrupt before that notification is received, retaining the charge.

## Restated model obligations

The host MUST install original teardown custody before activating inbound delivery.
Historical queries MUST NOT recreate that live continuation or activate it again.

- Requirement: `LC-001`
- Model: `PSrc/Channel.p:40`; monitor: `PSpec/Safety.p:36`.

Each modeled direction MUST reserve its exact prefix-inclusive bytes before
complete-frame delivery, hold one frame, and preserve its cumulative charge on
uncertainty. An applied ACK MUST name the current original sequence and actual
consumer; chunk receipt MUST NOT return a usable frame credit.

- Requirement: `LC-002`
- Model: `PSrc/Channel.p:110`; monitor: `PSpec/Safety.p:45`.

CapDone MUST settle a call once while retaining its slot through Running,
ReplyReady and ReplySending. Only the exact consumed-write ACK MUST release that
slot. Immediate responses MUST share one held input slot and withhold inbound
consumption until their own bounded response is consumed.

- Requirement: `LC-003`
- Model: `PSrc/Channel.p:139`; monitor: `PSpec/Safety.p:114`.

A validated terminal MUST send Final consumption before synchronous destruction
or joins. Final and retired directions MUST NOT admit another frame or accept a
late ACK that recreates capacity.

- Requirement: `LC-004`
- Model: `PSrc/Channel.p:139`; monitor: `PSpec/Safety.p:144`.

Cancellation MUST remain independent of a stalled writer and occupied endpoint
metadata credits. Channel-long streams MUST NOT borrow the six finite endpoint
request credits, and uncertainty MUST NOT refund admitted stream bytes.

- Requirement: `LC-005`
- Model: `PSrc/Channel.p:40`; monitor: `PSpec/Safety.p:155`.

A live Launch entry MUST remain held until original resource closure, both joins,
native retirement and resource release are separately observed. Native retirement
and report COMMIT MUST NOT be inferred from channel EOF or known terminal outcome.
A bounded final result MUST follow report COMMIT.

- Requirement: `LC-006`
- Model: `PSrc/Channel.p:252`; monitor: `PSpec/Safety.p:164`.

The caller MUST retain execution directories after a known outcome whenever
original cleanup is unresolved. Directory deletion MUST require the independent
safe-cleanup observation, rather than terminal validation or report COMMIT alone.

- Requirement: `LC-007`
- Model: `PSrc/Channel.p:40`; monitor: `PSpec/Safety.p:172`.

## Traceability and implementation bridge

Every row is partially verified: the P obligation has executable controls and
mutations, but the finished runtime path and native/SQL observations are pending.
The source bridge names operations and lines in the final frozen API; none is an
end-to-end refinement certificate. The P key contains original remote authority
atoms. The local API FrameRef contains incarnation, direction and sequence only;
remote administrative authentication belongs to its adapter.

| Requirement | P model | Monitor/property | Production code | Tests/traces | Status |
|---|---|---|---|---|---|
| LC-001 | dispatch: custody then activation; prepare retains original identity. | mPrepared/mCustody/mActivated; no historical resurrection. | run_channel.request:371, prepare_direction:652, activate_direction:666; Connected install and remote original-association checks pending. | tcStartup/tcProbeStartup, tcLocal/tcProbeLocal, activate-before-custody mutant. | partially verified |
| LC-002 | reserve/hold/deliver/ack and retained spent counters. | mReserved/mDelivered/mAckApplied/mFreed/mSnapshot. | reserve_frame:681, publish_frame:723, consume_frame:742, remaining_bytes:783; real pre-body receipt and mailbox ordering pending. | tcByte, tcStale, tcIdentity, tcBoundary and probes; chunk-credit, stale-sequence, uncertain-refund mutants. | partially verified |
| LC-003 | CapDone retains Ready; reply keeps Sending; immediate input waits for its response. | CallAdmitted/Settled/Released and ImmediateHeld/Released histories. | reserve_write:829, consume_write:848; host Running/ReplyReady/ReplySending and immediate transitions pending. | tcReply, tcImmediate and probes; completion-slot mutant. | partially verified |
| LC-004 | terminal validation then nonblocking Final; cancellation can win before ACK application. | TerminalValidated/AckSent/Destroy and stale/late ACK assertions. | consume(delivery, Final):640, consume_frame:742, retire_direction:772; actual reader wait/join pending. | tcTerminal and tcRetirement with probes; final-credit, terminal-destroy, retired-ack mutants. | partially verified |
| LC-005 | control destruction independent of held data; six finite metadata slots remain separate. | CancelReturned requires socket closure; Metadata forbids stream lifetime; spent never decreases. | Connection:289 close and ResourceDrain:183 contract; independent close/recv/send and endpoint handling pending. | tcCancel and probe; cancel-writer-queue, stream-metadata, uncertain-refund mutants. | partially verified |
| LC-006 | bounded four live entries; ordered EOF; independent NativeRetire, joins, resources and ReportCommit. | mEnd/mEntryReleased/mPublished histories. | CloseResult:195 node/transport/resources; finished remote Launch/resource journal and report owner paths pending. | tcActive, tcEnd, tcDeath, tcReport and probes; release-resources, end-overtakes mutants. | partially verified |
| LC-007 | CleanupSafe consumes all original observations; DeleteDirectory refuses terminal/COMMIT-only state. | mCleanup/mDirectoryDeleted. | Run cleanup disposition and outer caller cleanup propagation pending. | tcReport/tcProbeReport; outcome-delete mutant. | partially verified |

## Reproduction and evidence

Run `python3 run.py --schedules 1000 --probe-schedules 2000 --seed 697` from this
directory, or invoke `check.sh`. Set PATH to the installed P and dotnet tools.
`run.py` snapshots only the pproj and P sources, compiles that snapshot and checks
15 normal controls plus 15 probes. Probe cases deliberately exit one at their
registered exact witness after required histories; an unrelated assertion,
compilation failure or arbitrary nonzero exit fails the runner. Stale and Identity
are aliases for the same combined sequence/direction/full-identity schedule;
they do not constitute two independent coverage claims.

`mutate.py --schedules 100 --seed 697` compiles an unmodified source-only control,
then thirteen source-only mutations. It changes only PSrc/Channel.p. Source hashes
prove the monitors and scenarios remain unchanged. Every mutant must compile and
fail at its exact registered safety assertion. Generated PChecker assemblies are
never copied between projects. The existing remote-execution/runner.py supplies
bounded invocation only; its exact source hash is part of the evidence packet.

Each checker uses 1,000 maximum steps, a 60-second internal limit, a 65-second
outer process limit and a 1-GiB checker limit. Strict records distinguish the P
child exit from any optional memory measurement wrapper. Checker logs, generated
traces, own command exits, source hashes and initial setup diagnostics belong in
the frozen evidence packet rather than being silently replaced by later green runs.

The independent bounded replay used seed 701 and twenty schedules per normal
control. All fifteen controls returned child exit zero with zero bugs (300
actual schedules), and all fifteen probes returned child exit one at their exact
registered witness (fifteen actual schedules). Seven selected mutants compiled
and failed at their registered safety assertions: completion-slot, retired-ack,
terminal-destroy, cancel-writer-queue, release-resources, outcome-delete and
end-overtakes. Their unmodified controls passed seventy actual schedules.
The review found no actionable defect within the declared bounded scope. Its
private report records commands, child exits, limits and the final API hash;
these results do not replace the initial packet's larger run or runtime gates.

## Abstractions and remaining verification

The checker explores bounded, directed scripts, with a nondeterministic terminal
ACK/cancel order. Repeated schedules do not explore arbitrary command histories.
DirectedCompletion checks completion of those finite scripts under P scheduling;
it establishes no unbounded fairness, network recovery or physical liveness.

Frames and writes are byte-count atoms. The payload ceiling 16,777,216, four-byte
prefix, directional lifetime 67,108,864, chunk ceiling 65,536, maximum 257 chunks
and four active Launch entries are accepted production constants. Two held call
slots sample the production outstanding-call bound; they are not a new cap limit.
The model's one immediate slot and four-data/two-control metadata slots remain
independent. Exact wire bytes are tested at the cumulative boundary and first
excess; the chunk-count calculation is symbolic, not an OS allocation measurement.

No model event proves a socket write, passive receive, jail enforcement, task join,
truthful native retirement, SQLite COMMIT, token placement or membership secrecy.
NativeRetire, ResourcesRelease and ReportCommit represent truthful external
observations assumed from their original authorities. ResourcesRelease includes
original capability-work drain and placement cleanup; socket closure alone is
insufficient evidence even though it is a model precondition. OwnerDeath removes that
producer and retains unresolved custody; historical reads do not repair it.
Real socket cancellation, large jailed retained-report/load_result execution,
remote artifact/context validation and cold correspondence to serialized adapter
state need their own runtime controls. Separate physical hosts, absent owner
checkout, remote LSP and default registered daemon assembly remain product gates.
