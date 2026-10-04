# Exact service and command custody

The owner journal now retains complete Compile and Launch requests, immutable
command offers and separately reserved native requests. Service and native
identities remain distinct. Offers use the original service's fixed command
role and never allocate a placeholder native UUID.

The schema and row queries are named SQL compiled through Parrot/sqlc. Repeated
generation reproduces every affected binding and schema constant exactly.
Format 3 adds the offer table transactionally after validating format-2
metadata, configured limits, bounded headers and reservations.

## Review correction

Independent review found one reachable migration defect. In format 2,
cancelling a child before allocation creates a fence with no UUID. Successful
final-result collection freezes that fence with an empty request and no
terminal body. The first migration predicate incorrectly rejected its frozen
state and would refuse the entire journal reopen.

The corrected predicate permits UUID-less cancelled or frozen fences only
with an empty request and absent terminal body. State, type and reservation
checks remain. A regression follows the actual cancellation, final-result
readback and collection APIs, then migrates the prior-format database while
preserving an unrelated live child. Restoring the old predicate compiles but
fails the intended reopen assertion. Four corruption controls retain refusal
for invalid state, body, terminal evidence and under-reservation. The reviewer
rechecked the repair and found no remaining actionable issue.

## Evidence and scope

Root independently passed the final 166-test storage gate and five custodian
actor controls after the repair. The candidate's full client gate passed
2,752 tests before integration with the preceding provenance slice. Its final
command exit was recorded directly. After integrating the reviewed commits,
root passed the combined package gate: 170 core, 166 storage and 2,754 client
tests. The package command, combined lint and documentation checks each exited
zero. Existing client fixture skips remain explicit in the gate log. Format
and reproducible SQL generation also passed.

Two further compiling mutations remove exact-offer comparison or the
collection guard. They fail changed-offer admission and retained unknown/orphan
evidence controls respectively. Each source restoration was byte-exact.

Real SQLite tests cover reopen, original UUID readback, cancellation before
and after offer/native reservation, late receipts, count and byte bounds,
malformed persisted headers, concurrent openers and conservative collection.
The offer count has its own persisted bound; it does not increase the existing
64 actual-child ceiling.

The storage and actor interfaces retain bounded opaque bytes. They do not
validate executable command purpose, SandboxPolicy or native clearance. That
trusted assembly, complete resource services and separate-host product tests
remain outstanding. Final ToolOutcome readback cannot release physical service
evidence until a real recovery-transfer contract proves the handoff.
