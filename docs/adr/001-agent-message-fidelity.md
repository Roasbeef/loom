# ADR-001 — AgentMessage mirrors pi's provider-message shapes

**Status**: accepted · **Date**: 2026-08-24 · **Spec ref**: Part 6 item 2, Part 7

## Decision

`core`'s `AgentMessage` family mirrors the structure of pi's
`AgentMessage`/`ToolResultMessage` types (source of truth:
`earendil-works/pi`, dev branch, `packages/agent/docs/harness.md` §0.7 and
the `packages/protocol` source types), diverging only in representation:
Gleam ADTs with exhaustive variants instead of TypeScript tagged unions,
and total decoders at every boundary.

Concretely: user / assistant / tool-result roles with the same field
vocabulary (content blocks, tool calls with id + name + arguments, usage
attribution), plus custom roles carrying a registered runtime schema name
and opaque JSON payload.

## Why

Mirroring the shapes makes the pi format-4 import (follow-up track 6) a
mechanical decode-and-re-mint; diverging would turn it into a semantic
mapping project with its own bug surface. pi's shapes are themselves
provider-shaped, so we inherit their fit to the Anthropic/OpenAI wire
formats. Representation divergence (ADTs, opaque ids, no optional-field
sprawl) costs the import nothing because the import path decodes pi's JSON
into our ADTs anyway.

## Consequences

- The WP-A implementer reads pi's message types before defining ours and
  documents any field we deliberately drop or rename in the module docs.
- Field-level divergence beyond representation requires updating this ADR.
