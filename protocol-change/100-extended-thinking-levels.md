# protocol-change/100: Extended provider thinking levels

**Status**: ACCEPTED after independent review. **Affects**: Part 1.5 provider routing vocabulary.

## Problem

The strand vocabulary already stores `xhigh` and `max`, but routing collapses both to `high` before provider dispatch. Responses models that support these levels therefore never receive the requested effort, and catalogue defaults cannot express either level.

## Proposal

Extend `provider/model.ThinkingLevel` with `ThinkingXHigh` and `ThinkingMax`. Preserve them across role and resolved routing, catalogue parsing and strand seeding. Responses requests encode them as `xhigh` and `max`; the existing OpenAI-compatible, Anthropic and Gemini adapters map both to their existing high setting. Existing levels and durable strand encoding remain unchanged.

## Alternatives

Keeping the collapse silently loses the requested effort. A raw string or side map adds a separate mechanism without improving this closed vocabulary; the typed extension is smaller.

## Consequences

This extends the in-VM provider dispatch vocabulary carried by `RequestTarget` and `ResolvedModel`; exhaustive matches must handle the new constructors. Provider support is model-specific: a Responses endpoint may reject a level its selected model does not support. No durable schema or gateway frame changes are required. Independent review confirmed the routing and dialect boundaries. Focused tests cover parsing, live configuration, routing, request encoding and saved-strand round trips.
