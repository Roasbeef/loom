# Khepri compatibility probe

The pinned Khepri candidate works with an actual Gleam caller on OTP 29 in the
bounded scenarios tested. Three independent BEAM nodes preserved conditional
updates and stable operation receipts across leader isolation, lost replies and
full restart. This supports continuing the metadata-library work for issue #697;
it does not adopt Khepri into Loom or establish the complete D3 acceptance gate.

## What ran

The scratch project pins Khepri 0.19.3, Ra 3.2.0, Horus 0.5.1, aten 0.6.0,
gen_batch_server 0.10.0 and seshat 1.0.1. The toolchain was Gleam 1.19.0-rc2,
OTP 29.0.5 and ERTS 17.0.5 on macOS. Its actual Gleam module calls a fixed
Erlang transaction adapter. No arbitrary Gleam closure enters a replicated
transaction. The upstream packages and one scratch controller emit deprecated
catch warnings on OTP 29; successful compilation is not a warning-free build.

The source, lock file, launchers and raw evidence remain under
`/private/tmp/loom-distributed-khepri-spike/runtime`. The `evidence/source-lock.json`
and `evidence/capacity-source-lock.json` files pin the two source sets. This is a
local experiment, not a repository gate or a reproducible shipped fixture.
The longer API and runtime reports are retained under
`/private/tmp/loom-distributed-wave2/khepri-{api-review,runtime-probe,capacity-probe}.md`.

| Check | Observed result |
| --- | --- |
| Actual Gleam bridge and Horus extraction | Create, read, replace and same-request replay passed. Horus refused the deliberately forbidden transaction call. |
| Concurrent conditional updates | Two members submitted different replacements against the same observation; exactly one applied, and both requests retained their original decisions. |
| Lost application reply | A caller committed revision 3 and discarded its result. Replaying its saved request through another member returned the original receipt without another increment. |
| Native timeout after commit | A suspended designated reply member caused a real timeout; majority readback proved revision 4 had committed before that member resumed. Replaying the same request retained revision 4. |
| Leader isolation | The majority committed revision 5. The isolated former leader returned revision 4 as a hint, while its authoritative read and conditional update timed out. |
| Reconciliation after healing | The same minority operation ID and request became a conditional rejection against revision 5. No retry minted another operation. |
| Full restart | Three fresh BEAM instances reopened the durable directories, read revision 5 and replayed the historical revision-3 receipt without rolling state back. |
| ABA and identical values | A -> B -> A and physical delete/recreate both refused the old observation. Replacing identical bytes advanced the wrapper revision once; replay advanced it zero times. |
| Receipt saturation | At 128 receipts, new create/replace attempts could not mutate records, while old receipts remained usable before and after restart. An independent inventory matched the 42,664-byte logical reservation counter. |
| Byte saturation | With 4-KiB values, the fixture admitted 30 receipts and 255,642 logical bytes, then refused another mutation while retaining old receipts. |
| Binary keys and atoms | After metrics warm-up, the atom count stayed fixed across 113 further key operations. |

The corrected three-node run exited 0 in 5.814 seconds. The separate full-BEAM
restart exited 0 in 1.029 seconds. The additional single-member ABA/count-capacity run
exited 0 in 0.868 seconds; a separate byte-capacity control exited 0 in 0.561 seconds. Each launcher captures the command's own exit and has
a finite outer deadline; individual database and peer calls are finite too.

## Consequences for the API

Routing hints and authoritative observations need distinct opaque types. The
probe's authoritative read executes a fixed read function as an explicit `rw`
transaction, which takes the replicated-command path. Khepri's
`favor => consistency` path instead uses a local query with an applied-index
condition derived from leader metrics. It timed out correctly in this partition
schedule, but that observation does not establish its general linearizability.

A prepared mutation needs a stable operation ID, exact request bytes and digest
persisted before first submission. The transaction records its decision together
with the conditional update. Reconciliation uses those same bytes and identity.
Khepri's internal duplicate protection, based on a temporary reference and
acknowledgement, does not replace an application receipt that must survive a
caller restart.

The timeout witness returned `{ok, {error, timeout}}`. A decoder that treats an
outer `ok` as an applied mutation would be wrong. The production bridge must
totally decode the closed application decision and conservatively retain
uncertainty for transport or unexpected responses. A missing receipt is not
proof that an earlier command cannot still commit.

Observations bind a creation identity and wrapper revision as well as exact key,
store lineage and envelope bytes. Recreating an identical payload cannot revive
an old observation. Gleam's opaque values enforce construction rules; transaction
checks still enforce concurrent validity.

## Limits and remaining work

These are finite experiments, not a proof of arbitrary-history linearizability,
TLS membership or Loom ownership and handoff. The scratch cluster uses local
BEAM distribution; it does not validate the production TLS configuration. The
single-member capacity run does not establish concurrent or replicated quota
behavior. Neither run measures production throughput or worst-case memory.

The scratch Prepared value uses a closed external term, not the bounded,
versioned durable decoder the library needs. Receipt reclamation, disk exhaustion, a long partition soak and mixed-version
upgrade remain untested. The proposed first wrapper must retain a finite
admission limit until a replay-retention contract permits reclamation.

Unsuccessful attempts remain in the evidence. A first partition fixture used
matching replacement cookies and allowed reconnection; its successful read was
not a partition witness. A fresh-controller decoder needed its known fixed tag
atoms loaded before safe external-term decoding. The first inventory used a
literal `'*'` key instead of Khepri's wildcard condition, and the first metrics
call loaded 318 atoms. The corrected fixtures address those causes; none of the
failed attempts counts as a passing control.

Disposition: bounded runtime compatibility passed. The library API, operational
retention lifecycle, production decoder and complete D3 acceptance remain open.
