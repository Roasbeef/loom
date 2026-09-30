# Typed capability results

The six capability modules changed by [protocol 057](../protocol-change/057-typed-capability-results.md)
decode stable response fields inside the satellite. Programs can match records
and error variants without parsing JSON text or rendered channel errors.
This is a source API migration; existing programs must use the new selectors
and result types when rebuilt against the bundled capability library.

## Peer inspection and delivery

`peer.inbox` returns `InboxPage`, `peer.history` returns `HistoryPage`, and
`peer.received` returns `ReceiptPage`. Each continuation is an `Option` of the
corresponding cursor type. Start with `first_pending`, `first_history`, or
`first_receipt`; pass the returned continuation back to the same reader.
An empty page can still have a continuation. Receipt keys are hashes, so a
new-arrival poll starts a fresh scan rather than retaining an arrival watermark.

`inbox_get`, `received_get`, and `sent_receipt` return optional records.
`None` means the caller-owned view has no matching record. `send` returns an
`Admitted` receipt whose request contains the source identity, target strand,
retry identity and complete body. Its optional source metadata preserves
absence separately from custom host metadata. Admission proves storage;
inspection neither consumes nor acknowledges a message.

`roster` returns `List(Link)`. Catalogue lifecycle, exported strands, wake
permission and the stable activity envelope have types. Sender-owned message
payloads, model descriptions and Git observations remain open `report.Value`
values. A caller can apply its own decoder where that application owns the
schema. Arbitrary metadata supplied by a custom host uses `CustomMetadata`.

`SessionId`, `EntryId`, and `OpId` are nameable through `cap/peer`, including
on a host which does not offer child-strand operations. Parse persisted IDs
through the module's `parse_*` functions and render them through `*_to_string`.
`PeerDenied(code, message)`, `PeerUnavailable(reason)`, and
`PeerResultMalformed(reason)` preserve different failure categories.
`InvalidSelector` rejects a persisted identity or cursor before making a call.

## Workflow and execution

`workflow.step` still returns a child `Handle`, but its error type now
distinguishes host denial, transport unavailability and malformed results.
Code that displayed an error string must explicitly render or match that error.

`execution.receive` starts with `execution.first_input()` and takes an
`InputCursor`. The returned message carries the next cursor. A restored cursor
goes through `input_cursor`; `input_sequence` renders it for persistence.
`Closed(reason)` and the typed serving loop's `InputClosed(reason)` preserve
the host's closure diagnostic. Endpoint decoders and callbacks retain their
application-level error text; capability failures use `ExecutionError`.

## Child and job identities

`strand.Handle.operation` and `Delivery.operation` use `OpId`;
`Delivery.entry` uses `EntryId`. These aliases reuse the core opaque identities
and their total parsers. A result field's requirement is `Required` or
`Optional`, while the existing `required` and `optional` builders remain the
normal way to construct fields.

`job.start` returns a `JobId`, which later polling, stdin and kill calls take
directly. For persistence, use `job_id_to_string` and `parse_job_id`.
`job.from_start()` and `job.after(watched)` remain the normal polling cursors.
Stdout and stderr positions have different types; their explicit parse/render
helpers support persisted positions without permitting accidental interchange.
Timeout and cancellation remain separate facts because both can be true.

Malformed strand and job answers have dedicated error variants. Invalid IDs,
negative stream cursors and malformed optional spill references fail explicitly
rather than becoming usable handles or absent output.

## Granted schedule cadence

Schedule creation and listing retain `when` for display and add `cadence`:
`Interval(seconds, expiry)`, `Cron(expression, utc_offset_s, expiry)`, or
`OneShot(at_unix_s)`. `Expiry` contains the granted fire count and lifetime
bounds. A relative one-shot exposes the absolute instant resolved by the host;
cron keeps its fixed offset and does not follow daylight-saving changes.

Programs match these variants rather than parse the display sentence.
`MalformedScheduleResult` identifies a response contract violation separately
from an unavailable schedule service. The additive wire field changes neither
schedule requests nor durable schedule records.
