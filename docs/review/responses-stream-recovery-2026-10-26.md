# Responses stream recovery validation

Checked October 26, 2026 against source commit `ce0308379`, integrating main `9b8621641`. This records local execution and independent source review. Hosted CI and Linux signoff are separate exact-head gates; their results belong in the pull request.

## Observed failure

The operator reported repeated failures at `response.output_item.done` for output item zero. The adapter reported `item_parts_unclosed` at sequences nine and eleven, after approximately 337,000 to 342,000 body bytes. Manual continuation sometimes resumed work and sometimes repeated the same failure.

Those diagnostics establish that a tracked part had not reached its closed state when the output item closed. They do not establish whether the provider omitted an event, sent an incomplete item, or exposed a compatibility defect in the parser. No raw stream was retained or recovered. The implementation does not relax validation or claim an upstream root-cause fix.

## Recovery contract

[Protocol 103](../../protocol-change/103-bounded-responses-recovery.md) gives only that existing guard a typed recovery classification. The gateway forwards it without fallback. Runtime settlement retains the failed response and its request accounting, then the machine narrows its captured policy to at most three total generation attempts. A stricter configured budget wins. The narrowed policy survives serialization and subsequent transport or orphan failures. The summary hook contract carries the same structured ceiling.

The count is conservative: earlier generation attempts consume the allowance, including attempts that failed for other reasons. It is not a count of HTTP requests. The existing fallback behavior for ordinary transient failures is unchanged.

The diagnostic reports internal item/part kinds, an allowlisted status, closure state and counts. Unknown remote strings, IDs, text, arguments and ciphertext do not enter it. The tests inspect the scrubbed error, not only the raw adapter report.

[Protocol 102](../../protocol-change/102-extended-thinking-levels.md) separately preserves `xhigh` and `max` from catalogue settings and durable strand state through Responses encoding. Both public and subscription builders have direct assertions. Other adapters retain their prior high-equivalent requests.

## Executed local checks

The integration owner reran these checks after the workers restored all mutation controls:

| Check | Result |
| --- | --- |
| `bash scripts/check.sh provider machine` | Exit zero; 332 provider tests and 102 machine tests. |
| `bash scripts/check.sh runtime` | Exit zero; 211 tests and runtime retention checks. |
| `bash scripts/test.sh conformance --match responses_recovery` | Exit zero; three recovery scenarios. |
| `bash scripts/test.sh conformance --match responses_e2e` | Exit zero; public and subscription tool/reasoning round trips. |
| `make fmt-check lint` | Exit zero; existing non-gating warning census remains. |
| `make doc-check prelude-check client-check` | Exit zero after refreshing two citations shifted by the new retry-policy code. |
| `git diff --check` | No whitespace errors. |

Before main integration, focused reasoning tests also covered catalogue parsing, live configuration, route/vision mappings and saved-strand round trips. The final hosted and remote gates must validate the integrated head; those earlier runs are not substituted for them.

## Negative controls and review

Removing catalogue branches makes the new parsing regression fail. Restoring the old reasoning collapse makes routing regressions fail. Removing sticky retry-policy persistence makes the assistant mixed-failure, orphan and summary mixed-failure regressions fail. Routing bounded corruption through gateway fallback makes its dedicated test fail with a backup settlement and two attempts. Each temporary mutation was restored byte-for-byte, followed by passing tests.

Independent review found no actionable production correctness issue. It verified typed eligibility, immediate forwarding, accounting and drain precedence, persistent bounds, stricter budgets, structured diagnostics, both reasoning builders and documentation mirrors.

Review of the integration fixture found an oracle that waited for the preceding transport owner to exit. That wait could manufacture the ordering under test. The corrected fixture records the previous PID without waiting and checks its liveness directly before invoking the next request's begin callback. A live-owner negative control verifies that oracle. The completed response must contain exactly the final text, while failed attempts retain empty content and cannot execute partial tool calls.

The integration script's owner exits promptly after delivering its frames, so the fixture observes ordering without forcing a slow drain. Existing stream and gateway tests separately hold an owner alive and assert no terminal delivery or fallback until release. The new error uses that unchanged machinery; no additional process or timer mechanism was added for recovery.

## Limits

No live account inference was used as a test oracle. Local scripted subscription coverage does not prove an account's entitlement or native upstream acceptance. The enclosing tool jail cannot exercise nested native helper confinement, so full Linux signoff and hosted enforcement/end-to-end checks remain necessary. No production daemon was installed, restarted or modified by these tests.
