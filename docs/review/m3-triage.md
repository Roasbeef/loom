# M3 review triage — decisions and fix plan

Adjudication of the six adversarial reviews of the M3 surface (session,
events, runtime ×2, gateway, simulation) plus the DST runner. Two areas
drew independent duplicate reviews; where they converged it is noted, and
the convergence raised confidence rather than wasting it. Every finding is
fixed, deferred with a reason, or accepted. As with the M2 triage, the
disposition here is this document's ruling, not the reviewer's severity.

## The shape of it

Nothing shipped is broken on a hot path today: the two most serious
subsystems — precise rewrite and multi-strand escalations — are admin and
approval paths nothing yet drives in anger. But both are load-bearing for
what comes next (M4 code mode leans on the escalation trust boundary and
the sandbox), so they are the fix wave's spine, and they need design, not
patches.

## Fix now — the two subsystems that need real work

### A. Precise rewrite (session/storage) — the erase feature that doesn't erase

The rewrite is the "erase a leaked secret from history" operation, and two
independent reviews reproduced it failing at its one job.

| ID | Sev | Finding |
|---|---|---|
| SES-rewrite-wal | CRITICAL | The erased copy is swapped over the original before the original's WAL siblings are unlinked, and the actor never checkpoints, so the next open recovers the old WAL frames into the new file — the erased text returns. Both deletes are `let _ =`, so a failed unlink still returns success. Fix: checkpoint-and-truncate the source WAL before the copy; propagate unlink failure. |
| SES-rewrite-lease | CRITICAL | The lease is sampled once before the copy, never held; a writer opening mid-rewrite commits durably and the swap discards it. Fix: hold a lease in the original for the rewrite's duration; re-verify before the rename. |
| SES-erase-scope | HIGH | Erase visits only `entries.payload`; a needle in `pending.entry`, `op.tool_args`, `fact.*`, `strand.last_result`, or `usage_ledger.details` survives. Fix: rewrite every store the needle can reach, and widen the audit test to grep after planting in each. |
| SES-migrate-order | HIGH | Schema DDL and migrations run before `acquire_lease`, so a refused open still writes under a live writer, and an `UnsupportedVersion` refusal still writes v1 tables into a v99 file. Fix: acquire the lease first; migrate only after. |
| SES-create-race | HIGH | Racing creates insert multiple catalog rows and brick the file; one opener dies on an unhandled `$busy` clause. Fix: single-writer create under `BEGIN IMMEDIATE`; handle busy as `OpenError`. |
| SES-rewrite-tmp | MED | Concurrent rewrites collide on one fixed temp path and can swap in an unerased copy with success. Fix: unique temp path per rewrite. |
| SES-adopt-foreign | MED | `open` adopts a foreign SQLite database instead of refusing `CorruptSession`. Fix: verify the schema marker on open. |

### B. Multi-strand escalations (runtime) — grants cross the boundary

Two independent reviews and my own code read converged on this. The
escalation subsystem was designed as the trust boundary for approved
capability widening; as built it leaks.

| ID | Sev | Finding |
|---|---|---|
| RT-esc-attribution | HIGH | `clear_tool_call` hands the union of *every* approved escalation's grants to whichever call clears next, on any strand — an approval for one strand's denied tool widens an unrelated call elsewhere. The record carries no op/strand/tool/call to attribute by. Fix: attribute an approval to the exact `{op, strand, step, call}` it was raised for; a clearance loads only its own grants. |
| RT-esc-double | HIGH | The consume CAS runs after `tools.clear` already used the grants, and a lost race is swallowed as `Ok(Nil)`, so two drivers both clear and both dispatch under one approval. Fix: consume before clearing; on a lost consume race, discard the clearance verdict. |
| RT-restart-leak | HIGH | A strand-actor restart (not tree death) leaks its unlinked live effects; recovery treats them as orphans and a ReplaySafe tool re-executes concurrently with its still-running first execution, the exclusivity gate evaporating across the restart. Fix: link/monitor live effects to the strand so a restart reaps them, or record them durably enough that recovery waits. |
| RT-await-aba | HIGH | `await_strand_result` is latest-wins over one `strand.last_result` register; a child that starts a second run before the parent's poll makes the first result permanently unobservable, returned as `Error(Nil)`. Fix: key the awaited result by operation id, not latest-wins. |
| RT-defer-api | MED | The ORCH-L4 fix never reached `settle_poll`, which still compares against `message_api(message)`; deferred states carry no captured api. Fix: capture the request api on the deferred state durably (the claim in docs is not yet true). |
| RT-abort-summary | MED | Aborting structural-summary work doesn't park on the live summary effect, so a settled summary's usage is dropped. Fix: extend the ORCH-M3 abort-retention to the summary path. |

## Fix now — cheaper, isolated

| ID | Sev | Finding | Fix |
|---|---|---|---|
| EV-proj-rewrite | HIGH | Projections have no rewrite-invalidation guard (search does); a checkpointed projection serves pre-rewrite state forever. | Grow the `Checkpoint` contract a generation field; the driver re-reads the store handle and surfaces the pull error. No production consumer yet, so cheap now. |
| EV-sync-txn | MED | `search.sync` reads its cursor outside `BEGIN IMMEDIATE`; concurrent syncs duplicate every row. | Read the cursor inside the transaction. |
| EV-sub-idempotent | MED | `bus.subscribe` is not idempotent; a second join double-delivers, one unsubscribe leaves membership. | Make subscribe idempotent per `{session, topic, pid}`. |
| EV-bridge-sup | MED | `bus.bridge` is linked and unsupervised; its crash killed its starter. | Supervise it or trap its exit. |
| GW-token-timing | MED | Bearer token compared with `==` (timing oracle); the tree already ships constant-time compare in `broker/token`. | Reuse `crypto:hash_equals`. |
| GW-token-perms | MED | Token file chmod'd 0600 after creation — a world-readable window. | Create `O_EXCL` at 0600. |
| SIM-1 | MED | The wire-damage property accepts any corrupt stream that decodes, without validating the frame; the doc's claim is untested. | Re-encode the decoded frame and compare, or assert the decode is a fault. |

## Deferred, with reasons

- **RT-harness-gap / SIM-6** (the interleave harness and simulation cover
  none of the new M3 machinery — parallel batches, escalations, strand
  restarts): this is the *coverage* gap that would have caught A and B
  earlier. Fold into the fix wave's verification, not deferred: every fix
  above lands with a simulation scenario or interleave case that fails
  before it. That is the standing lesson from the DST runner finding its
  own bugs — a fix without a failing test that precedes it is not done.
- **EV-unicode-tokenizer** (FTS5's default tokenizer makes CJK/emoji
  unsearchable): real but a tokenizer-config choice, not a defect;
  document and defer to a search-quality pass.
- **SIM-2 / SIM-5** (shrink relabeling; the `kill_tree` no-op invariant
  coupling): correctness-of-reporting and a latent coupling safe under the
  one-crash cap; fix opportunistically with the harness-coverage work.
- The LOW/NIT items across all six reports: batched into the fix wave
  where they touch a file already being changed; otherwise logged.

## Accepted, no change

- **GW server-side frame cap / catch_up amplification** (authenticated
  DoS): a client that authenticated already holds a session; the threat
  model (design §5.1) does not defend a hostile authenticated operator of
  their own session. Documented, not defended, matching the M2 ruling on
  the analogous provider case.

## What the reviews found sound — recorded as evidence

The DST runner's load-bearing checks are proven sound by construction
(crash-fired catches a vacuous run, the ledger check has teeth, keying is
pure-from-seed). The M2 fix wave's four items genuinely landed (abort
retains settled content and usage on the run paths, parallel dispatch is
source-ordered, request_api is captured, acceptance CAS-guards the leaf).
The gateway's self-approval privilege-escalation path is airtight, its
token entropy a real 128 bits, its protocol decode total and depth-bounded,
with no cross-session seq confusion. FTS5 injection held against twenty
hostile probes. The reserved `escalation/` prefix guard holds. These are
the parts not to re-derive.
