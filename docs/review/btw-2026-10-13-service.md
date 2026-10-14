# Cold acceptance: service/runtime

Verdict: APPROVE

Reviewed current HEAD `69d4d6461e3aab34b5c1b279e21c4c06c98d6f1d`, the supplied service diff, the protocol-087 contract, side-query architecture, production wiring/callers, side-service regressions, and the installed client build dependency's Weft ownership/outcome contract. No source changes, builds, tests, commits, or Git mutations were performed. Gate and real-UI execution remain the root's responsibility.

## Medium or higher findings

None. No concrete reachable service/runtime defect requiring reopening was found.

## Load-bearing checks

- Effective capture: `runtime/strand_runtime.gleam:1853-1864` puts request-local transformed context into the actual generation spec. `serve.gleam:4157-4173` composes the side observer with the existing provider relay; `wiring.gleam:1380-1383` uses the same provider request builder as dispatch. The observation carries provider configuration and tool definitions, rather than executable tools. `btw.gleam:151-176` captures that generation and matches its terminal by strand and response-entry snapshot. Polls and structural summaries do not become candidates.
- Frozen/fallback behavior: `btw.gleam:245-270` extends only the matching latest candidate, and only a text-only Stop response contributes an assistant message. `btw.gleam:441-471` identifies the actual answering provider/model through gateway route facts and preserves the applicable thinking overlay; unknown identity drops the candidate. Existing attachment conversations are separate values, so new captures and main compaction do not change their base. `fresh` and `request_for` retain system/tool/output settings and append side history after the base. Side `ForResolved` dispatch takes a singleton attempt (`provider/gateway.gleam:1714`), preventing cross-service fallback.
- No-tool boundary: the side collector calls only the provider gateway. It has no tool runner, Agency, runtime operation admission, or context-hook path. `btw.gleam:889-915` rejects empty/oversized/tool-call terminals; reasoning is not included in the side answer or its replay. `generated_tool_call_is_never_executed_or_replayed_test` exercises the provider wire and proves no second dispatch or durable transcript entry.
- Bounded ownership/history: `btw.gleam:236-242` retains at most four 8 MiB latest bases. Admission separately bounds two flights plus uncertain reservations, eight attachment conversations, eight exchanges, 8 KiB questions, 128 KiB side history, context fit, and a reserved 32 KiB answer allowance. Collector text/event bounds and its state timeout remain fixed across deltas. Refresh and Ask cannot replace a live owner's conversation; Clear can remove content without releasing its flight.
- Clear/Forget/Reset: `btw.gleam:278-286,338-357` cancel requests and retire conversations without deleting flights or uncertain reservations. Gateway startup sends Reset before serving its new connection namespace (`gateway.gleam:1170-1171`), and detach sends Forget (`3102-3104`). A reused owner cannot Ask or Refresh while its old flight exists; Preview and terminal updates never recreate an absent conversation. Old private content therefore cannot be attached to the new namespace.
- Drain proof: collector and provider are adopted before Begin (`btw.gleam:810-855`). The installed Weft dependency's `note_outcome`/`seal_outcome` seals managed outcomes against ownership proof, withholding pending proof and replacing lost/unconfirmed proof with distinct variants. Thus ordinary Completed/Failed/Crashed/Abandoned outcomes represent proven settlement here. `btw.gleam:715-738` preserves a lifetime capacity reservation for DrainProofLost, CancellationUnconfirmed, or a lost run without an outcome. A relay-lost event after an already sealed outcome does not erase its proof. The regression `lost_transport_drain_reserves_capacity_across_history_retirement_test` exercises actual abnormal transport-owner death, ordinary successful/failed reuse, and exhaustion across Clear, Forget and Reset.
- Single usage: `btw.gleam:750-774` records once at final flight retirement and deletes the flight/selector. Late or duplicate relay events find no flight. `distill.gleam:1626-1654` writes auxiliary usage with no transcript entry. Existing tests assert counts after multiple clean/uncertain terminals and after disconnect.
- Gateway authority: all five Btw actions pass the ordinary observer refusal before `side_query`; the private reply is unicast, keyed by the gateway-assigned connection number, and strand existence is checked. The authenticated observer regression covers all actions.

## Rejected variants

- Clearing/resetting a failed flight does not reclaim uncertain execution capacity: history and flight accounting are distinct, and the final typed outcome increments `uncertain` before dropping its relay.
- A late retired-flight result cannot create an old attachment history: updates require an existing conversation, and Ask/Refresh cannot replace it until the prior flight has retired.
- A generated tool call cannot reach main execution by retaining advertised definitions: definitions are inert request data; the service has no dispatch capability and marks the conversation failed before a follow-up.
- Main fallback reasoning cannot be appended under the original service identity: terminal capture pins the actual identity before retaining any settled assistant blocks, or removes the candidate.

## Low/informational

No low-severity defect claimed. The service tests read for this pass exercise direct Capture with a resolved target; they do not directly drive the production observer's context transform plus a settled cross-provider fallback. The source path above supports that claim, but an integrated regression would strengthen evidence for future refactors. This is a coverage observation, not a reopening finding. No test execution was claimed in this read-only pass.
