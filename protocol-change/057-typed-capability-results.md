# Protocol 057: type capability results and identities

**Status**: Implemented following operator approval; integration validation
and independent review are in progress.
**Affects**: `cap/peer`, `cap/workflow`, `cap/execution`, `cap/strand`,
`cap/job`, and `cap/schedule`; generated capability declarations and schedule
response projections.

## Problem

The capability library already presents most stable responses as records and
variants, but several boundaries still discard that structure. Peer calls
return JSON text. Workflow and execution calls render channel errors into
strings. Child operation and entry identities are ordinary strings, while job
and execution cursors can be interchanged with unrelated integers. Schedule
inspection exposes cadence only as a sentence intended for display.

Every program then has to reconstruct the same contract. A malformed identity
can pass a primitive string decoder, and a program cannot match a transport
failure separately from an invalid response without parsing diagnostic text.

## Decision

The six capability modules expose typed results and validate stable domain
fields at their existing wire boundaries. Peer responses are decoded into
pages, inputs, receipts and links inside the satellite. Absent lookups use
`Option`; pending, history and receipt cursors have distinct types. The peer
wire continues to carry its existing bounded JSON text. Arbitrary message and
application values remain structured open values where their schema belongs
to the sender rather than to the capability library.

Workflow and execution errors preserve denial codes and messages, channel
unavailability, and malformed response diagnostics as separate variants.
Execution input cursors have their own nonnegative domain and closure results
retain the host's reason. These changes do not add retries or reinterpret
application-level failure text.

Child operation and entry references reuse the opaque types and total parsers
in `core/ids`. Public aliases and conversion functions in `cap/strand` let a
program use those identities without importing a harness module. A declared
result field uses `Required` or `Optional`, converted to the existing wire
boolean at the boundary. Job identities are opaque and validated against the
existing host grammar. Stdout and stderr cursors have separate nonnegative
types; `from_start` and `after` remain the normal cursor constructors.

Schedule creation and listing retain their rendered `when` field and add a
structured `cadence` response. Its wire forms are:

```text
{kind: "interval", seconds, expiry: {max_fires, expires_after_s}}
{kind: "cron", expression, utc_offset_s,
 expiry: {max_fires, expires_after_s}}
{kind: "one_shot", at_unix_s}
```

The host projects these values from its existing timing record. The satellite
decodes them into interval, cron and one-shot variants; it never parses the
display sentence. A relative one-shot reads back as the resolved absolute
instant, as it already did in the display field. Bounds and offsets retain
their current units and validation rules.

## What was considered

Leaving JSON and rendered errors at the public boundary preserves signatures
but repeats decoding in every program. Replacing all strings and integers with
wrappers would also obscure values whose meaning is already clear: file
contents, output text, HTTP bodies and open application results remain in
their existing domains. The change targets stable capability contracts and
identities rather than every primitive value.

Parsing schedule display text would avoid a wire addition, but would make
formatting part of a machine contract. An additive cadence field preserves
the display surface while exposing the information the host already stores.

## Cost and limits

This is a source API migration for code-mode programs using these six modules.
The generated prelude, executable examples, default-host fixtures and bundled
capability build must be regenerated or migrated together. Existing peer,
workflow, execution, strand and job wire shapes remain unchanged. Schedule
responses gain one field; durable schedule encoding and request shapes remain
unchanged. No effect-plane frame version, database schema, authority, delivery
priority, retention policy, dependency or process mechanism changes.

Typed receipts still prove admission rather than consumption. Inspection is
still non-consuming, pages retain their existing scan and continuation rules,
and receipt cursors still order hashed keys rather than arrival times.

The [migration guide](../docs/capability-types.md) gives the public types and
conversion helpers programs use when rebuilt against this library.
