# 071: Two immutable remote Compile attempts

Status: approved and implemented. Independent contract and implementation reviews found no remaining production blocker; package and composed acceptance receipts remain separate.

## Problem

The code-mode pipeline compiles once and, only for a complete unused-import-only diagnostic, removes those imports, re-vets and compiles once more. Both calls retain the original Build phase. Remote custody currently has one Compile child address, so the changed second canonical input correctly conflicts with the first. A second UUID alone cannot create another child address. Weakening immutable input checks would invalidate recovery evidence.

## Decision

Keep exactly two pipeline attempts, `Original` and `UnusedImportRewrite`, in `codemode/compile.CompileAttempt`. Add an `attempt` field to CompileRequest. The first call uses Original; the existing single rewritten call uses UnusedImportRewrite. Local compilation preserves its current behavior. Attempt selection never changes PhaseIdentity, operation, step, budget, grants or absolute deadline.

Keep existing core ChildRole constructors/bytes unchanged. Add only `CompileRewrite` and `CompileRewriteCommand`. Their child-address role arrays are exactly `["compile_unused_import_rewrite"]` and `["compile_unused_import_rewrite_command"]`. They have no ordinal or peer-selected string. CompileService and CompileCommand remain the physical service/command purposes; the checked ServiceKey chooses its corresponding child origin and CommandRef native origin. Launch is unchanged.

Preserve every existing version-1 ServiceKey byte form. Add a closed rewrite ServiceKey encoding `[2, <complete version-1 Original Compile ServiceKey>, <rewrite UUID>, <rewrite input SHA-256>]`. A new checked `command.rewrite_service_key` constructor accepts only an Original CompileService predecessor and a different UUID, derives the same parent/scope/operation/step/registration/contract fields, and uses the Rewrite origin. There is no nested version-2 predecessor. The complete predecessor is immutable lineage in the key itself, so it is covered by the existing canonical whole envelope and journal identity/digest checks. Existing CompileInput bodies and transfer ceilings remain unchanged. New accessors project the predecessor and attempt without granting authority.

Each attempt has its own unchanged canonical CompileInput, allocation root, immutable offer, native UUID/Prepared association and closed completion. Existing successful artifact derivation uses the actual attempt UUID/input digest. The resource journal still admits only one native association per physical service. No schema or format bump is needed solely for this additive key encoding: existing full canonical key/input blobs retain new lineage, while old rows decode exactly as before. If implementation inspection finds a scalar schema assumption preventing this, it must be reported rather than silently migrated.

## Checked admission and recovery

Before a fresh rewrite reservation, the owner custodian must retrieve the exact predecessor service envelope and retained completion from its own immutable rows. Decode the completion against that key/enrollment and require BuildRejected. Apply the existing all-or-nothing unused_imports.rewrite to the retained original source and diagnostics, re-vet under the same original selected contract, and require the new source, ordered generated selection, dependencies, enrollment, seam, policy seed and stage ceiling to be exactly the derived values. Generated source bytes cannot be changed: select only the original retained generated entries still imported by the new Vetted. Missing, malformed, successful, unknown or unresolved predecessor evidence refuses rewrite before new admission.

The executor repeats this validation independently against its resource journal's retained original input and closed committed Compile completion before admitting/claiming the rewrite. Owner-provided lineage or diagnostic bytes alone never authorize it. Repeated checked requests only read the same attempt: changed source or predecessor conflicts, and lost replies never remint UUID, renew clearance or reconstruct a live preparation Claim. Original/Rewrite historical recovery retains both original addresses and successful producer selection.

The absolute pooled deadline is unchanged. Each native wall is the remaining original budget, bounded by the retained build ceiling. Build grants remain empty. Exactly one rewritten invocation is possible; a second BuildRejected is final. Unknown Original outcome cannot authorize Rewrite.

Launch producer lookup must select the exact retained successful Compile attempt matching every artifact field, including request UUID/input digest. It must validate the complete key/input/completion and original parent. Substituting Original for a Rewrite artifact is refused. No live connection or retry authority is reconstructed from history.

## Costs and alternatives

Two permanent service/native child records and their existing fixed allowances replace one for the rewrite case. The per-ToolKey closed offer ceiling becomes three: OriginalCompile, RewriteCompile and Satellite. Existing owner/resource quotas remain aggregate; exhaustion refuses the second attempt. No new dependency, transport route, retry policy or generic attempt framework is introduced.

Executor-owned rewrite was considered. It would require two native associations inside one immutable service, transformed-source/edits provenance in closed completion, changed historical command expectations, and moving rewrite ownership out of the existing pipeline. Explicit bounded attempts preserve those existing boundaries with fewer state transitions.

## Acceptance

Canonical controls preserve Original bytes and reject nested/invalid rewrite keys. Real remote unused-import failure must produce one rewritten build and Launch from its exact artifact, with two distinct service/native origins and unchanged parent/ledger/deadline. Both admission owners refuse missing/wrong-parent/wrong-source/malformed predecessor evidence. Mixed/truncated/location-wrong diagnostics and failed re-vetting never produce a second build. The second failure is final. Lost replies/restart recover original records without new effects; near-deadline rewrite never renews time. Launch rejects substituted Original and sibling producers. Compiling mutations must fail runtime assertions at these boundaries.
