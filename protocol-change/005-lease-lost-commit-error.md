# protocol-change/005 — add `LeaseLost` to `CommitError`

**Status**: ACCEPTED 2026-08-26 · **Affects**: Part 1.1 `CommitError` ·
**Raised by**: issue #6 (`runtime/api.enqueue`) · **Implemented**: core +
storage + runtime + session

## Problem

The frozen sketch gives commits three failure modes: `StaleExpectation`,
`Corruption`, and `Faulted(reason: String)`. The single-writer rule
(pi §1.5, design §3.5) adds a fourth condition that is none of those. A
writer whose lease has been stolen — an opener found it expired, took it
with a bumped fence, and is now the session's writer — has every commit
refused by `check_and_renew_lease` before a single write is applied.

Today that arrives as `Faulted("writer lease lost: now held by \"x\"")`.
It is a real condition wearing a string, and the string is the only thing
that distinguishes it from a full disk, a corrupt page, or a closed
handle. `runtime/api`'s admission paths consequently collapsed it into
`ApiError.CommitFailed`, and a caller could not tell "someone else took
this session" from "the backend broke" — two failures whose remedies are
opposite. Retrying is right for the second and always wrong for the
first: every reload reads the same file and every retry meets the same
fence.

## Proposal

```gleam
pub type CommitError {
  StaleExpectation(failed: SeqExpectation)
  Corruption(report: CorruptionReport)
  Faulted(reason: String)
  LeaseLost(held_by: Option(String))
}
```

`held_by` names the current lease owner when the backend could read one,
and is `None` when the lease row was cleared rather than taken (a precise
rewrite clears it so the swapped-in file starts unleased). Both mean the
same thing to a committer: this process is no longer the writer, nothing
was applied, and the fix is to reopen rather than to retry.

The memory backend never produces it — it has no lease — so the variant
is SQLite-only in practice while remaining part of the shared vocabulary
every commit site must handle.

## Impact

Every exhaustive `case` on `CommitError` gains one arm; the compiler
finds them all, which is the point of not using a catch-all. Concretely:
`session.ensure_strand`, `runtime/api`'s admission and seeding paths,
`runtime/strand_runtime`'s commit paths, and the storage backends'
error mapping. No durable format changes: the variant never crosses a
wire or a file, only a function return.

`runtime/api` maps it to a new `ApiError.SessionStolen(held_by:)` and
finishes the admission immediately instead of retrying.

## Decision

**Accepted.** The alternative — leaving the condition inside `Faulted`
and having callers match on the reason string — was considered and
dismissed: it makes a load-bearing distinction depend on prose that no
compiler checks, and it is exactly the "reporting something other than
what you prove" failure the issue exists to close. The narrower
alternative of classifying only inside `runtime/api` was dismissed for
the same reason; the backend is the layer that *knows*, so it is the
layer that should say.
