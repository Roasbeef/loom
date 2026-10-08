# protocol-change/078: partial no-path diagnostics

**Status**: IMPLEMENTED LOCALLY 2026-10-08; validation pending.
**Authorization**: the owner requested all fixes in issue #924, including its
same-run diagnostics reproduction.

## Problem

The session manager holds one package server at a time. Queries against two
unavailable owners followed by a healthy control select only the control's
server. `diagnostics(None)` previously settled that server's open documents
and returned `Settled([])`. Its unqualified clean-code documentation let a
program read that partial scope as a clean workspace.

## Decision

A no-path diagnostics query MUST return an `Unsettled` snapshot of the current
server's open documents, even when those documents settle. It MUST NOT claim
workspace coverage. No selected server, a failed acquisition, or a failed
settlement still returns the existing error. An explicit file query keeps its
owning-server acquisition and bounded settlement, and MAY return `Settled`.
`Settled([])` establishes cleanliness only for that explicit requested scope.

No capability or gateway wire fields change. The existing `Unsettled` variant
also represents incomplete coverage, rather than only an expired deadline.
Post-write diagnostics retain their explicit document scope and behavior.

## Cost and alternatives

This removes the false workspace-clean state without maintaining a failure
ledger or starting every package server for a snapshot. A ledger could retain
old failures while still missing owners never queried. A project-wide query
would require an explicit inventory and coverage contract; the current optional
file argument carries neither.

## Verification

The regression runs an unavailable owner, a healthy control, the no-path
snapshot, and explicit healthy and unavailable file queries in one manager.
The snapshot must be `Unsettled([])`, the healthy file must settle, and the
unavailable file must return `NoServer`.
