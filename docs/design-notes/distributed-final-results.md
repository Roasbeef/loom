# Retaining complete remote code-mode results

Status: proposed result representation, awaiting the owner's choice. This note
records a Launch integration constraint; it changes no runtime limit or API.

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

## Proposed representation

The recommended user-visible result is a bounded preview plus a reference to the
complete canonical value retained by the owner. The reference binds the value's
digest, byte length and storage identity. Rerunning the program is never a way to
recover that value. The alternative is to keep the entire structured value inline
and introduce a separate bounded final-message codec and reservation profile.
The owner must choose this representation before implementation.

The existing text-blob helper supplies useful storage machinery, but does not
establish the required custody. It retains full structured details alongside the
text reference, has no pre-effect reservation for the future result, and uses
staging plus rename without an fsync guarantee. The proposed complete-value
reference therefore needs these explicit obligations:

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

The owner store currently has a 256-MiB lifetime budget. Reserving 224 MiB for
every final code-mode message leaves insufficient space for even one existing
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
