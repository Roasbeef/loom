# Retaining complete remote code-mode results

Status: accepted design after independent review. The owner selected bounded
previews and durable references to complete reports. Implementation and the
satellite, restart and retrieval controls below remain required. This note does
not claim that the capability is already available.

## Why the satellite limit is insufficient

A code-mode satellite can return a MsgPack outcome with a 16-MiB payload. The owner later wraps
that value in a final tool message and persists it as JSON. That final encoder
currently accepts at most 256 KiB. A valid satellite result can therefore exceed
the final persistence limit even after its executor receipt has committed.

The expansion is reachable through the public report builders. A list containing one string of
16,777,173 NUL characters encodes to exactly 16,777,216 cap payload bytes. Its JSON
value needs 100,663,042 bytes because each NUL becomes `\u0000`. If the existing
text-overflow blob write fails, the final message retains both that value and
its rendered text. Their combined JSON needs 218,103,261 bytes before message
metadata. These counts follow the current encoders; they are source arithmetic,
not a completed satellite regression.

The boundaries are `cap/runtime.encode_outcome`, `cap/report.to_msgpack`,
`tools/codemode.ran_outcome` and `runtime/effects.encode_tool_outcome`. The owner
custodian calls the last encoder before `storage/owner_custody.finish`.
Increasing a Launch child-receipt limit does not increase the final-message
limit or establish that the owner can retain the result.

## Accepted representation

The accepted user-visible result is a bounded preview plus a reference to the
complete canonical value retained by the owner. The reference binds the value's
digest, byte length and storage identity. Rerunning the program is never a way to
recover that value. The alternative is to keep the entire structured value inline
and introduce a separate bounded final-message codec and reservation profile.
The owner selected the reference representation; the inline alternative is not
the implementation path.

The report belongs in the existing per-session owner SQLite tool row. The
filesystem text-blob helper retains full structured details alongside its text
reference, has no pre-effect reservation, and writes by staging and rename.
Using the owner row avoids a second storage system and a file/database handoff.
The complete-report reference has four obligations:

- Reserve the full supported value and reference allowance before the effect.
- Retain and durably bind the complete bytes before acknowledging the final result.
- Validate the original digest, length and association after restart.
- Preserve or transfer that custody when the exact final session message commits.

A failed value write must preserve uncertainty or report an admitted failure.
It cannot fall back to an unreserved huge message or label a truncated value as
complete. The implementation must bound metadata, nesting and container counts
as well as byte length. Logical database quotas do not bound process memory or
write-ahead-log size.

## Why a larger blanket limit is costly

The owner store supports a configurable lifetime reservation budget of at most
256 MiB. Even at that ceiling, reserving 224 MiB for every final code-mode
message leaves insufficient space for one existing
32-MiB child allowance once request and identity metadata are included. A compact
structural codec reduces the expansion, but still needs an explicit complete
bound and charges that allowance before the result is known.

Collection also remains part of Launch integration. Ordinary owner rows can
shrink to identity fences after exact session commit and release. Physical
Compile/Launch rows currently keep collection pending while their resource or
command obligations exist. Increasing the store limit would delay exhaustion;
it would not discharge those obligations or reclaim their reservations.

The selected implementation must use the existing owner actor and original tool
identity. Any persisted profile and allowance are immutable from first admission.
Named SQL and generated bindings must validate the profile and BLOB length before
reading the value. Recovering old history cannot grant a larger allowance or
fresh execution authority.

## What is retained

One bundle contains two canonical MessagePack segments. The first is the
program's existing Outcome body: either a complete value or a failure message
and complete details. It contains no authenticated frame header, token or channel
identity. The second contains independent owner observations: the exact compiler fingerprint (`sha256-` plus 64 lowercase hex digits),
both enforcement stages, and the complete existing bounded capability-call log.
Keeping these segments distinct prevents a program from supplying its own
enforcement or call history.

The header is the eight bytes `LOOMRV01`, followed by two big-endian u32 lengths.
The terminal and metadata bytes follow, without trailing data. SHA-256 covers
the whole bundle. Binary values, non-string map keys and integer/float tags
survive; conversion through the existing JSON display renderer would lose them.

| Item | Maximum bytes |
| --- | ---: |
| Canonical terminal body | 16,777,216 |
| Owner metadata | 262,144 |
| Header | 16 |
| Complete bundle | 17,039,376 |
| Final ToolOutcome JSON | 262,144 |
| Stored digest/profile bookkeeping | 128 |
| Reserved final allowance before execution | 17,301,648 |

The reference spelling fits within the final JSON allowance. The 128-byte
bookkeeping allowance covers stored digest/profile fields, not another copy of
that spelling. The current cap frame limit stays unchanged: its envelope still
uses part of the 16-MiB frame, so this table does not grant a larger frame.

The report decoder has a separate fixed profile. The terminal body permits at
most 254 container levels, 65,536 nodes across all siblings, 65,536 array elements
or 32,768 map entries. Map keys consume nodes. Scalars and total terminal bytes
must fit the terminal ceiling. A raw scan precedes decoding; a bounded structural
walk precedes encoding. Canonical readback rejects alternate encodings, duplicate
keys, invalid UTF-8, nonfinite floats and trailing bytes. The native 256-KiB
decoder keeps its existing smaller profile.

These node and container limits are new admission constraints beyond the old
cap frame's byte/depth limits. Launch must apply them when admitting the terminal,
so a result it accepts cannot later fail a hidden, smaller final-storage profile.

Metadata has depth 16, at most 8,192 nodes, at most 128 entries per container and
8,192 bytes per string. Its checked types describe the call log, build/node
reports, reported versus unreported stages, and complete versus degraded
enforcement. Only program values remain arbitrary structured data. Each stage
has a 65,536-byte canonical allowance and at most 128 applied/skipped entries
together. The call log keeps its existing 128-record, 64-byte capability,
96-byte summary and 48-byte error-code bounds. Its counters and times are
nonnegative u64 values. The full bounded log costs at most 36,732 canonical
bytes; both stages, log and manifest fit below 169 KiB. Invalid producer metadata
fails finalization explicitly; it is never silently cut to claim completion.

## Admission, commit and recovery

Trusted tool assembly selects `OrdinaryFinal` or `CodeModeReportV1` before fresh
admission. That immutable profile reserves its final allowance under the existing
configured global quota. A model-supplied name or later result cannot enlarge an
ordinary reservation. Existing child reservations remain separately charged.

The managed renderer first commits the checked report through the pinned owner
and original ToolKey. Only after receiving that internal receipt does it create
a bounded preview/reference ToolOutcome. Final commit independently checks the
exact reference, identity and profile. The existing runtime ToolOutcome codec
and ordinary-tool runner contract remain unchanged.

A crash between report commit and final commit leaves report bytes and unknown
final outcome. Recovery cannot reconstruct the exact missing final message from
those bytes or rerun the program. Failed retention fences the original run before
returning any diagnostic; a later generic error result cannot discharge that
unresolved custody. A no-terminal vet/compile refusal can retain its bounded
failure message without fabricating a report.

The preview visitor produces at most 4,096 UTF-8 bytes without first rendering
the entire value as JSON or text. Known metadata gets a bounded truthful summary.
The complete final message must pass the existing 256-KiB codec. Its original
call identity is bounded before admission, and arbitrary extra details cannot
enter this closed final schema. The report-bearing ToolResultMessage has
exactly `{kind: "code_mode_report_v1", reference: <canonical URI>}` in its
structured details. Its bounded text content is a preview, its original call ID
and name stay unchanged, and `is_error` agrees with the retained Outcome. The
final commit compares that exact reference with the retained row. A generic
ToolFailed result cannot discharge retained or unresolved report custody.

A refusal before a terminal Outcome exists uses a separate closed schema:
`{kind: "code_mode_not_run_v1", stage: "vet"}` or the same shape with
`stage: "compile"`. Only the trusted vetting and compilation refusal branches
emit it. Its text is bounded to 4,096 bytes, `is_error` is true, and no report may
already be retained for the row. A program error or satellite failure cannot
be relabeled from its tool name or `is_error` flag. This shape preserves ordinary
refusals without letting a missing terminal value masquerade as a completed
program. Existing producer and physical-child discharge requirements still apply;
a compilation refusal alone proves no physical cleanup.

Owner format 5 adds the immutable profile/allowance, report BLOB and digest.
Scalar headers and aggregate quotas are checked before loading report bytes.
Reopen validates one report at a time, including canonical encoding, digest and
original identity. The custodian validates existing final-reference associations
through the runtime decoder before publishing its door. An older format is
refused unchanged; reopening never migrates it into more execution authority.
The owner connection sets SQLite `synchronous=FULL` and checks its readback,
alongside WAL. Tests cover that setting and process-crash recovery; they do not
establish hardware flush or actual power-loss behavior.

Exact session commit and existing run/physical discharge permit collection to
release unused reservation. They do not permit deleting the report. Collection
keeps its actual byte charge, digest and original identity with the permanent
fence. Unknown rows retain their full reservation. The owner database remains a
durable session companion through close, archive, reopen and compaction for as
long as a transcript reference may be read. Transcript-only export is not a
transfer of this companion's contents.

## Reading a saved report

A reference has the fixed form
`result://<session-uuid>/<result-entry-uuid>/<sha256>/<byte-length>`, at most
160 bytes. It is a data name, not an OS path or bearer credential.
The proposed `cap/report.load_result` returns a typed report containing the
original Outcome, manifest, enforcement stages and call log.

The host installs `report.result_chunk` on the owner side of the authenticated
capability router. A registered remote workspace does not move this door to its
executor filesystem. The current session, result entry, digest and length must
all match. SQL returns only a bounded chunk after checked scalar headers; it
does not copy the whole report on every request.

One invocation can admit at most 261 chunk reads across all references, each
with at most 65,536 payload bytes and 512 envelope bytes. Their aggregate encoded
reply allowance is 17,238,528 bytes. The helper gathers at most one complete
bundle, concatenates its bounded list once, and runs the report decoder. Existing
deadlines, call credits and pooled budgets still apply. No read refreshes them.
Only hosts with this door installed advertise the helper and its working example.

## Formal correspondence

Extend the existing OwnerDischarge P model with immutable profile/allowance and
one durable report identity, digest and length. Its monitor must observe actual
reservation, report commit, final-reference commit, exact session readback,
collection and restart transitions. Retained report alone grants neither a
final message nor run discharge. Collection preserves its bytes and charge.
Executable tests bridge the symbolic model to SQL length guards, canonical
decoding, digest checks and authenticated capability reads; P proves none of
those implementations or filesystem synchronization by itself.

## Required evidence

Exercise the NUL-array witness through actual satellite framing and final owner
retention. Cover successful and failed value writes, restart, conflicting final
bytes, a lost COMMIT reply, maximum nesting and metadata, and capacity filled
after original admission. The maximum admitted result must still be retained in
full and match the exact session message without replay. Mutation controls must
reject acknowledgement without receipt and release before final commitment and
producer drain.

The [integration guide](distributed-runtime-integration.md) tracks Launch and
separate-host acceptance. The [custody architecture](../architecture/remote-custody.md)
describes the existing owner obligations that this representation must preserve.

Independent Sol review verified the encoder arithmetic and current persistence
boundaries. It corrected the budget description above: 256 MiB is the maximum
configurable ceiling, and an actual store may admit less. The large satellite
regression remains required implementation evidence.
