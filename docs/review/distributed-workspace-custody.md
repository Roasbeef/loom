# Workspace custody and bounded transfer review

The workspace journal reserves canonical invocation bytes plus the full
32-MiB completion allowance before returning admission. A serialized transaction
commits Started before returning its opaque first Claim. Duplicate or recovered
Started rows return Unknown. A recovered Accepted row may still obtain its
first claim: durable admission alone is not permission to execute.

Only the original live claim can finish. Exact completion bytes commit before
Finished is returned; exact receipt-digest acknowledgement removes payloads but
keeps permanent UUID/digest/size fences. Independently opened SQLite connections
serialize with BEGIN IMMEDIATE. Bounded scalar/header projections precede BLOB
reads, and recovery validates retained bodies one row at a time. Source SQL,
generated Parrot/sqlc bindings and embedded schema remain separate artifacts.

The transfer keeps the existing TLS frame ceiling. Fixed 64-KiB chunks have
exact offsets; a checked header fixes direction, total size and SHA-256.
The receiver refuses truncation, surplus, wrong order and digest mismatch.
The caller still owns application authentication, a whole-exchange deadline
and bounded connection credits. Content transfer grants no effect permission.

## Evidence

All twelve focused custody tests pass. A mutation granting a Claim from Unknown
fails exactly the recovery and independent-connection claim-count regressions;
ten other tests pass. Restoring the source restores twelve passes.

All six transfer tests pass. Real mutually authenticated TLS carries the maximum
9-MiB invocation and 32-MiB completion through unchanged 256-KiB frame admission.
An isolated compiled-module mutation that skips the final digest check fails
exactly the corruption test, with five other tests passing. The shared source
and production build artifacts were never mutated.

The root independently ran all 132 executor tests with actual exit 0. The new
components compile warning-free and executor lint has no gating errors. A fresh
Astra adversarial review found no actionable code defect in the custody, SQL,
transfer or companion host-lifetime paths.

## Limits

Gleam opacity is not linear typing: trusted service code must consume a Claim
at most once. The matching receipt digest identifies evidence; it cannot prove
that a remote owner actually committed it. Owner persistence before ACK is a
separate binding obligation. The journal performs no filesystem effects.

The independent-open race runs two connections in one VM; no power-loss,
COMMIT-acknowledgement fault or separate-VM race was injected. Quotas bound
logical reserved content and lifetime rows, not physical SQLite/WAL or total
resident memory. During receive, retained chunks and their joined binary may
coexist. The maximum transfer test uses raw zero-filled bodies, not a joined
codec/journal/filesystem/owner-receipt pipeline. That pipeline and the shipped
two-host product gate remain required for issue #697.
