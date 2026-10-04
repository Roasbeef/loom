# Distributed transport and workspace contracts

This wave supplies prerequisites for issue #697. It does not yet enable remote
execution. Protocol 067 records the owner/executor boundary and remaining
end-to-end obligations.

## Independent review

Astra reviewed the workspace identity and semantic request contracts against
reachable callers, including the broker operation/step propagation. No
actionable findings remained. The contracts validate syntax and preserve
identity; consumers still owe authorization, filesystem checks and wire bounds.

The TLS review found one cumulative-deadline error: OTP could spend the full
connect timeout on TCP and then again on TLS. The fix establishes the deadline
before TCP, passes only its remainder to TLS, and closes the socket if either
phase exhausts it. A real-socket test injects a delayed TCP return and verifies
the remaining TLS allowance. A mutation that renews the allowance fails.
Native DNS may outlast OTP's connect timer; connection services must supervise
establishment, and the primitive documents that limit.

Astra separately reviewed the journal's Parrot/sqlc conversion. Parameter
order, guarded corruption projections, CAS and transaction ordering remain
unchanged. An independent SQLite probe passed 70 old-versus-generated
projection comparisons, including oversized blobs and invalid scalar types.
There were no actionable findings.

## Verification

The coordinator independently ran the focused workspace contract and broker
propagation tests. The TLS suite passed all 21 tests in an isolated checkout.
The generated journal suite passed all 19 journal/schema tests; executor lint
had no gating errors. These are component guarantees, not distributed system
signoff. Linux signoff on predecessor journal commit
`0cc11097d91228ed034d4d8330fe61df69c71d2e` passed with a clean skip census; it
does not cover this wave's additional code.

The Lean admission model has its own review and bounded implementation bridge.
It does not prove TLS, SQLite crash durability or the planned native adapter.
