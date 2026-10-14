# Current handoff

Baselined October 14, 2026 against main
`99975fe009e310f3084b83d06490df9eba947015`, which merges PR #982's per-strand
generation timing. Its previous handoff's pending-validation wording is
historical. Timing invariants and its verification boundary remain in
[that handoff](https://github.com/Roasbeef/loom/blob/99975fe009e310f3084b83d06490df9eba947015/docs/next.md).
Main also includes #972's register decoding and #979's Responses diagnostics
and deployment CI correction. The project-wide plan remains `docs/issue-plan.md`.
No installed daemon or operator configuration has been changed by this work.

## Responses Fast mode

The operator can set `service_tier = "fast"` or `"default"` on an
`openai-responses` or `codex-subscription` model entry. An absent selection
omits the wire field and retains provider defaults. Other values and dialects
refuse configuration. Typed catalogue and opaque per-provider gateway state
carry the choice without changing frozen request or resolved-model contracts.
Each actual attempt, including a fallback, sends its own entry's choice.
Reasoning effort, cybersecurity access, authentication and model identity are
independent.

Fast mode encodes OpenAI's documented `priority` wire alias. The current native
subscription endpoint rejected the newer `fast` spelling with HTTP 400; the
same tiny request with `priority` completed with HTTP 200. That response
reported `service_tier = "default"`, so the live test establishes accepted
request syntax, not Fast eligibility or a speed improvement. A request can
consume more allowance or incur higher charges if Fast processing is served.
Loom's configured price estimates are not authoritative subscription charges.

## Verification boundary

All 308 provider tests passed, as did both focused catalogue tier tests.
Client compilation was warning-free, both package lint gates had no errors,
and formatting and diff checks passed. Independent review, affected-package
validation, hosted checks and exact-head Linux signoff remain pending. No result from the prior login branch or main validates this feature
head. Record exact commands and exit statuses in the PR before marking it ready.

## Separate investigations

The login clock-tolerance fix is independently reviewed in PR #985, based on
`c47175004`. The audit session's recurring `event_unsupported` refusal remains
unresolved. Basic native requests, a tool-call/result replay and a large
synthetic context passed; no actual audit context was sent by the investigation.
An isolated private-context replay is awaiting explicit authorization after
automatic approval review rejected it as a separate export. This feature does
not change Responses event acceptance or claim to fix that failure.

## Next steps

1. Finish focused and affected checks, one independent adversarial review, and
   publish this scoped Fast-mode PR with the live served-tier limitation.
2. Obtain current-head hosted CI and Linux signoff. Merge, installation and
   enabling a potentially more expensive mode remain separate operator actions.
3. Continue the unsupported-event investigation once its required authorization
   arrives. Preserve login and Fast-mode PR boundaries.
