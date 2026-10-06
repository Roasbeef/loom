# Remote Compile: preserve the one unused-import rewrite

Status: proposed; awaiting the owner’s API decision. This document authorizes
no interface or protocol change. The recommendation was reviewed against the
source revisions named below.

Source inspection against the requested integration tree at `052b8d50c`. This is a design recommendation, not an implemented or tested change. No build or Git operation was performed.

## Recommendation

Approve a bounded, explicit Compile attempt identity: Original and UnusedImportRewrite, both beneath the same original ToolKey. Keep the existing owner pipeline responsible for the single rewrite and re-vetting. Give each physical Compile attempt its own immutable service input, UUID, allocation, command offer, native association and completion. Do not change operation/step, pooled budget, original absolute deadline or grants to obtain a second address. Preserve existing Original byte forms; add a distinct canonical address only for the rewrite attempt. This is an additive protocol change requiring owner approval and a protocol-change proposal, not something the default adapter can silently implement.

The rewrite attempt must have a durable checked predecessor relation to the exact Original service and retained BuildRejected completion. Before reserving it, verify the deterministic `unused_imports.rewrite` result against that retained completion, re-vet under the same selected policy, and filter generated modules from the new Vetted. Its canonical source/generated/dependencies must agree exactly with that result. There are exactly two permitted attempts, with no third constructor, ordinal supplied by a peer, changed-source reuse, or retry after uncertainty. Recovery reads existing attempts and completions; it never mints a replacement attempt to compensate for an unknown Original outcome.

This is the smallest change that retains the current pipeline behavior and leaves the executor's one-service/one-native-association invariant intact. It adds identity and lineage at admission, rather than a second native execution phase inside every existing Compile row.

## The current conflict

`packages/codemode/src/codemode/codemode.gleam:207` calls `compile_once` once, calls `rewritten` only on BuildRejected, then builds the freshly vetted result once. `compile_once:228` derives `identity.build_phase(config.identity)` for both calls. `rewritten:249` uses the all-or-nothing diagnostic parser and `vet.vet` with the original vet policy. `imported` changes the selected generated table when imports disappear. Execution.edits and the source sent to the satellite describe the rewritten program.

`packages/client/src/client/remote/compile_client.gleam:467` derives the same ToolChild Compile for both calls. `reserve_original:556` reads an existing child before considering a fresh UUID; `same_live_request:605` compares exact canonical input plus operation and step. The second call therefore correctly refuses. Minting a different UUID alone cannot help: `storage/owner_custody.admit_service_child` addresses the row by service_origin, and the original child remains immutable. Weakening this comparison would discard the evidence required for historical recovery.

`core/command.service_key:81` hardwires CompileService to Compile origin; `command_ref:128` derives CompileCommand. Both outer and native child addresses need attempt disambiguation. Changing only the outer service address would leave the second native command colliding with the original CompileCommand child.

## Why executor-owned rewrite is broader

The executor could accept the original source once and implement a deterministic rewrite internally, but the current protocol does not represent that operation. CompileFacts retains exact source, ordered generated source, dependencies, policy_seed and build_timeout_ms; the current service prepares that exact input once. The resource journal associates one immutable native key/Prepared digest with one outer invocation. Protocol-change/067's Compile completion custody addendum explicitly requires that immutable association, exact original-input command expectations, and no renewed deadline, UUID or clearance.

`executor/remote/compile_completion` stores one Before, Failed or Succeeded outcome. Succeeded contains one allocation, NativeAssociation and BuildProducts. `successful:146` derives ExecutorArtifact.request_digest from the original input digest and request_id/artifact_id from the original service UUID. It carries no effective rewritten source, rewrite notes, predecessor failure, second native association or transformation provenance. A historical success cannot reconstruct the source/edits the owner pipeline would report from this format.

Consequently executor-owned rewrite requires a bounded two-native-association journal state machine, checked rewrite provenance, executor re-vetting and generated-module selection, updated native command expectation derivation, and a completion format that retains effective source/edits. It also needs a way for the owner to receive that data and avoid its own second rewrite: CompileService currently returns only Compiled(result,enforcement). Returning a final BuildRejected to the unchanged pipeline would still trigger the owner rewrite path. Hiding edits or treating the unchanged original source as the launched source loses existing behavior. This alternative is coherent only as a larger approved contract revision.

## Exact contracts needing a decision

For the recommended explicit-attempt option, approve the spelling and ownership of a closed two-variant attempt identity, and how its checked predecessor relation is retained. Affected public boundaries are `core/remote_tool.ChildRole` and its canonical child codecs/addressing, `core/command.ServiceKey` construction/encoding/decoding and CommandRef/native_origin derivation, and `codemode/compile.CompileRequest` (currently vetted, dependencies, generated, identity only). The pipeline needs an explicit attempt argument rather than adapter-private call counting. The PhaseIdentity remains unchanged: attempt identity is provenance, never a budget axis.

Decide whether lineage is an added canonical CompileInput field or a separately checked durable admission record; it must survive restart and be validated at both owner custody and executor admission. If added to CompileFacts/input, specify a versioned closed encoding and fixed reservation ceiling adjustment. Old original input bytes must remain decodable unchanged. Related changes belong in `service_input`, compile_wire/protocol decoders, custodian/owner_custody and executor resource_journal/journal_codec validation, not merely in compile_client. The proposal must cover compatibility with existing durable rows.

Compiled itself can remain result+enforcement for explicit attempts. ExecutorArtifact can retain its existing fields, with the successful attempt's UUID and input_digest. LaunchInput.compiled_by must be the exact successful attempt ServiceKey, never an assumed Original Compile key. Current launch admission already checks exact producer and exact artifact against the retained successful completion; preserve those checks. The owner adapter must retain or project the successful producer through checked custody, including historical recovery, instead of deriving a single Compile child unconditionally. Review `compile_client.recover`, `live_identity`, `reserve_original`, `accepted_command`, `start_native` and the actual Launch adapter/assembly's producer lookup together.

For executor-owned rewrite, additionally revise CompileCompletion's closed Outcome/NativeAssociation representation and codec, journal immutable-association/cardinality rules, Compiled or another explicit result interface carrying effective source+edits, and the pipeline rewrite ownership contract. These are substantive mechanics changes to protocol-change/067, not implementation-only details.

## Regression shapes

- Real unused-import-only failure followed by one rewritten remote build; both immutable inputs retained, distinct original/rewrite outer and native identities, unchanged parent/operation/step/deadline/ledger, Build grants empty, and Execution.edits matching local behavior.
- Mixed diagnostics, truncated diagnostics, source-location mismatch or failed re-vetting admit no rewrite. A second BuildRejected is final; no third build.
- Reject rewrite admission without the exact retained predecessor failure, with a different rewritten source/generated table, or with another parent's predecessor. Changed input at either existing address still conflicts.
- Timeout/lost completion/native uncertainty on Original never authorizes Rewrite. Lost Rewrite reply recovers the same existing request and result without fresh preparation or native submission.
- Restart between first completion, rewrite reservation, native admission and completion reconstructs the same two records and selected successful producer; no process-local counter is required.
- Launch from Rewrite success passes exact producer/artifact checks. Substituting Original's key, a sibling's completion, same-parent wrong input digest or obsolete first artifact fails, including after receipt/native retirement.
- Aggregate attempts consume the original finite budget/deadline. Starting the rewrite near expiry does not renew build_timeout_ms or create a new budget ledger; Run grants remain unchanged.

No default remote assembly should ship until this choice and its protocol proposal are approved and the actual remote pipeline regressions pass. The current local default remains the verified behavior while this decision is pending.
