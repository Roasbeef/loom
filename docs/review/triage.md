# Review triage — decisions and deferrals

Adjudication of the 28 findings from the four adversarial reviews
(`durability.md`, `orchestration.md`, `security.md`, `provider-tools.md`).
Every finding is either fixed in the wave that follows this document,
deferred to a named milestone with a reason, or recorded as accepted.
Nothing is left unclassified.

Severity is the reviewer's. **Disposition** is this document's ruling.

## Fixed in the review-fix wave

| ID | Sev | Finding | Why now |
|---|---|---|---|
| PT-C1 | CRITICAL | `fs_edit` double-applies on duplicate lines; replay corrupts files | Falsifies a documented safety claim; crash recovery silently corrupts |
| PT-M1 | MEDIUM | Range hunks anchor-check only endpoints | Same defect class, same file |
| PT-H2 | HIGH | `fs.resolve_path` lexical-only; workspace symlink escapes root | Harness-side tools have no kernel jail behind them |
| SEC-H1 | HIGH | Pooled budget inert; amplification cap never fires | A security control that does nothing is worse than none |
| SEC-H2 | HIGH | `network: proxy` grants unrestricted egress, reports full enforcement | Silent widening — the one thing the design forbids |
| SEC-L5 | LOW | fd-3 policy temp file leaks on brutal kill | Cheap, same package |
| SEC-L6 | LOW | `skip:` enforcement entries not auto-checked | Makes the full-enforcement demand honest |
| PT-H1 | HIGH | SSE parser: unbounded carry, quadratic re-scan | Hostile proxy hangs a strand |
| PT-H3 | HIGH | Untrusted usage counts exceed durable msgpack range | Untrusted input producing an undurable durable object |
| PT-M2 | MEDIUM | Wiring drops the strand's per-turn thinking level | Configured budget silently ignored |
| PT-M3 | MEDIUM | Adapter overflow driven by provider-reported usage | Investigate; fix or record why acceptable |
| SEC-M3 + DUR-04 | MEDIUM | Decoders recurse without a depth bound | Reachable from the untrusted wire; one fix covers both |
| SEC-L4 | LOW | Duplicate-key precedence differs between the two decoders | Latent cross-codec desync at a durability boundary |
| DUR-01 | MEDIUM | Backends disagree on a negative `limit` | Two backends, one contract |
| DUR-02 | MEDIUM | Lease fencing path untested; doc claims otherwise | Either the test or the doc is wrong; find out which |
| DUR-03 | LOW | Branch-index metadata invariants unasserted | Conformance is the definition of correct |
| DUR-05 | LOW | Query-plan assertion weaker than the doc claims | Same |
| DUR-06 | NIT | Unbounded error-context strings from adversarial input | Cheap bound |

## Deferred, with reasons

| ID | Sev | Finding | Disposition |
|---|---|---|---|
| ORCH-H1 | HIGH | Interleave harness never crash-tests deferred, compaction, structural-summary, or navigation recovery; cannot race a steer against a live effect | **Folded into the DST simulation runner**, which is the next work item. Adding four hand-written scenarios would paper over the real gap: the harness enumerates only what someone thought to script. The runner's seeded explorer generates schedules and effect permutations, so these paths get covered by construction rather than by enumeration. Deferring by days, and to a better fix. |
| ORCH-M3 | MEDIUM | Abort discards a settled response's usage; under-counts billed tokens | **M3.** Bounded, one-directional inaccuracy on the abort path only. The fix belongs with M3's abort/usage work in `machine`, which no current agent owns; splicing it into this wave would race the fix agents for the same file. Recorded in spec-gaps. |
| ORCH-M2 | MEDIUM | `settings.tool_execution: Parallel` is silently a no-op | **M3.** Sequential dispatch is slow, not wrong. Real parallel dispatch needs planner work plus the broker's now-functional pooled budget underneath it — the SEC-H1 fix is a prerequisite. Until then the setting must not lie: documented as unimplemented. |
| ORCH-L4 | LOW | Deferred-handle `api` checked against the response's own api | **M3**, with the deferred-poll work. Already recorded as spec-gaps WP-D item 6. |
| ORCH-L5 | LOW | `abort_commit` exhaustion halts the strand, silently dropping the abort | **M3.** Requires 8 consecutive stale races to reach. |
| ORCH-L6 | LOW | Acceptance parents prompts on a non-CAS-guarded leaf | **M3.** Latent until idle tree-writes exist, which is M3's fork/navigation work. |
| PT-L1 | LOW | Duplicate `message_start` with empty usage zeroes accumulated counts | **Fix in the merge pass** (one-line: default to the accumulator, as `message_delta` already does). |
| PT-L2 | LOW | `unsupported()` returns a retryable error for poll/summary surfaces | **Fix in the merge pass** (terminal classification), so the machine cannot burn its retry ladder on a permanently absent surface. |
| SEC-untestable | — | bwrap, Landlock, seccomp, cgroup have no live kernel here | **CI requirement, not a code fix.** `make selftest` must run on a target-tier kernel before the enforcement matrix is trusted. Recorded as an M3 infrastructure item. |

## Accepted, no change

| ID | Finding | Why |
|---|---|---|
| PT-L3 | An operator-configured `base_url` with embedded userinfo could surface in a transport error | The API key itself is provably confined to headers (verified by the leak test). Credentials in a configured URL are an operator-supplied secret in an operator-supplied field; defending it would mean parsing and rewriting operator config, which trades a real capability for a hypothetical. Documented rather than defended. |

## What the reviews found sound

Worth recording because it is evidence, not absence of evidence. The
reviewers traced and confirmed correct: the machine's transition logic
against pi Part 3 across some fifteen areas (classify precedence,
overflow one-shot, threshold dedup, checkpoint order, terminal CAS
preserving a queued next run, cancellation routing, orphan reserved ids,
doorbell and stale-expectation loss-safety, `next_action` totality);
constant-time token comparison with no early exit; token single-use,
revocation, and cross-operation binding; most-restrictive policy
composition with prefix-aware roots (`/work` does not cover `/worker`);
escalation single-consume bounded by the wanted diff; 16 MiB frame caps
with no over-allocation; absence of shell or argv injection on the fd-3
and bwrap paths; and the seccomp filter's architecture, x32, and
AF_UNIX handling with correct TSYNC and no-new-privs ordering.
