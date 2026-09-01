//// Streaming machinery: typed stream events, the pure incremental SSE
//// parser, and the process pump that turns a raw HTTP chunk stream into
//// `StreamEvent` messages.
////
//// Layering, per the sans-io pattern:
////
//// - The SSE framing parser (`SseParser`) is pure: bytes in, events out,
////   plus carry state. Feeding the same bytes in any chunking yields the
////   same events, which is what makes it property-testable without
////   processes. It is also *bounded*: the carry buffer never exceeds
////   `max_line_bytes`, a multi-line event never retains more than
////   `max_event_bytes` or `max_event_data_lines`, a whole attempt feeds at
////   most `max_response_bytes`, and every byte is scanned exactly once. A
////   hostile or broken proxy therefore cannot exhaust memory with one
////   terminator-less line, empty list cells, or an endless sequence of valid
////   events; the stream fails in-band as a framing defect instead.
//// - Adapters compose the parser with their own pure accumulator into a
////   `ResponseMachine` — a fold over `HttpEvent`s producing
////   `StreamEvent`s.
//// - `run` is the only impure piece: it starts the injected transport,
////   folds the machine over the received chunks, forwards deltas as they
////   appear, and returns the single terminal event. One absolute deadline
////   spans the attempt; receiving a delta never renews it.
////
//// Consumption contract for `StreamHandle` (what WP-E relies on): the
//// subject delivers zero or more `Delta` events followed by exactly one
//// terminal event — `Settled` or `Failed` — and nothing after it. Deltas
//// are ephemeral display data and never prove anything about settlement.

import core/corruption.{type CorruptionReport}
import core/message.{type AgentMessage, type Usage, AssistantMessage, Pending}
import gleam/bit_array
import gleam/erlang/process.{
  type Monitor, type Pid, type Selector, type Subject, type Timer,
}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import provider/http.{type HttpRequest, type Transport}

// --- stream events ------------------------------------------------------

/// One streamed fragment of an in-progress assistant response. Deltas are
/// ephemeral: they exist for live display and frame persistence, and the
/// settled message is always authoritative.
///
/// Constructor invariants: `index` is the content-block index within the
/// accumulating response (provider-assigned, not necessarily contiguous);
/// `ToolCallDelta.call_id` and `name` are the values known so far and may
/// be empty on continuation fragments from providers that only send them
/// once.
pub type Delta {
  /// A fragment of a text block.
  TextDelta(index: Int, text: String)

  /// A fragment of a tool call's streamed JSON arguments.
  ToolCallDelta(
    index: Int,
    call_id: String,
    name: String,
    arguments_json: String,
  )

  /// A fragment of a thinking block.
  ThinkingDelta(index: Int, thinking: String)
}

/// One event on a provider stream, per the frozen contract (spec §1.5).
///
/// Constructor invariants: a stream delivers zero or more `Delta`s and
/// then exactly one `Settled` or `Failed`; `Settled.usage` equals the
/// usage inside the settled message and is repeated for direct ledger
/// writes; `Failed` errors carry redacted context only — never request
/// headers, bodies, or secrets.
pub type StreamEvent {
  /// A streamed fragment of the in-progress response.
  Delta(delta: Delta)

  /// The response settled completely.
  Settled(message: SettledAssistantMessage, usage: Usage)

  /// The request failed before settling; in-band, never a crash.
  Failed(error: ProviderError)
}

/// A provider response that has finished streaming: an assistant
/// `AgentMessage` whose stop reason is no longer `Pending`. Built from
/// `core`'s message types; the smart constructor is the proof boundary.
pub opaque type SettledAssistantMessage {
  /// Invariant: `message` is an `AssistantMessage` with a settled
  /// (non-`Pending`) stop reason.
  SettledAssistantMessage(message: AgentMessage)
}

/// Wraps an assistant message as settled. Fails on non-assistant messages
/// and on the `Pending` streaming intermediate.
///
/// ## Examples
///
/// ```gleam
/// let assert Error(Nil) =
///   stream.settle(message.UserMessage(content: [], timestamp: 0))
/// ```
///
pub fn settle(message: AgentMessage) -> Result(SettledAssistantMessage, Nil) {
  case message {
    AssistantMessage(stop_reason: Pending, ..) -> Error(Nil)
    AssistantMessage(..) -> Ok(SettledAssistantMessage(message:))
    _ -> Error(Nil)
  }
}

/// The settled assistant `AgentMessage` inside the wrapper.
///
/// ## Examples
///
/// ```gleam
/// // stream.message(settled) // -> message.AssistantMessage(...)
/// ```
///
pub fn message(settled: SettledAssistantMessage) -> AgentMessage {
  settled.message
}

/// Why a provider request failed, in-band. Every variant carries redacted
/// context only: status codes, provider error types, and human-readable
/// messages — never request headers, request bodies, or secret values
/// (spec §3.3 invariant 4).
///
/// Constructor invariants: `HttpError.api_error_type` is the provider's
/// machine-readable error type (`"overloaded_error"`, `"rate_limit_error"`,
/// …) or `""` when the body carried none; `retry_after_ms` is parsed from
/// the `retry-after` header when present; `UnmappedStopReason.raw` is the
/// provider's verbatim stop-reason string, per the total-mapping rule;
/// `NoSecret.secret_name` is the *name* of the missing secret, never a
/// value.
pub type ProviderError {
  /// The request owner accepted an explicit cancellation before settlement.
  ProviderCancelled

  /// The caller requested cancellation but no owner-authored terminal arrived.
  CancellationUnconfirmed

  /// The owner exited abnormally, so its descendants may still be live.
  DrainProofLost

  /// The transport failed before or during the response.
  TransportFailed(reason: String)

  /// The provider returned a non-success HTTP status.
  HttpError(
    status: Int,
    api_error_type: String,
    message: String,
    retry_after_ms: Option(Int),
  )

  /// The provider reported an error event inside the stream.
  StreamError(api_error_type: String, message: String)

  /// The stream ended before the response settled.
  StreamDisconnected(context: String)

  /// The stream carried data the adapter could not decode.
  MalformedStream(report: CorruptionReport)

  /// The provider used a stop reason the adapter does not know.
  UnmappedStopReason(raw: String)

  /// The requested role has no configured identity (dispatch-time
  /// counterpart of `resolve`'s `MissingIdentity`).
  NoIdentity(role: String)

  /// A resolved identity names a provider the gateway does not know.
  UnknownProvider(provider: String)

  /// The provider's API-key secret is not available from the store.
  NoSecret(provider: String, secret_name: String)
}

/// Renders an error as one human-readable line for in-band error results
/// and logs. Redaction-safe by construction: it only prints what the
/// error carries, and errors never carry secrets.
///
/// ## Examples
///
/// ```gleam
/// assert stream.describe_error(stream.TransportFailed("closed"))
///   == "transport failed: closed"
/// ```
///
pub fn describe_error(error: ProviderError) -> String {
  case error {
    ProviderCancelled -> "provider request was cancelled"
    CancellationUnconfirmed -> "provider cancellation could not be confirmed"
    DrainProofLost -> "provider ownership ended without proof of drain"
    TransportFailed(reason:) -> "transport failed: " <> reason
    HttpError(status:, api_error_type:, message:, retry_after_ms: _) ->
      "provider returned http "
      <> int.to_string(status)
      <> case api_error_type {
        "" -> ""
        _ -> " (" <> api_error_type <> ")"
      }
      <> ": "
      <> message
    StreamError(api_error_type:, message:) ->
      "provider stream error (" <> api_error_type <> "): " <> message
    StreamDisconnected(context:) -> "provider stream disconnected: " <> context
    MalformedStream(report:) -> corruption.describe(report)
    UnmappedStopReason(raw:) -> "provider used an unmapped stop reason: " <> raw
    NoIdentity(role:) -> "no model identity configured for role " <> role
    UnknownProvider(provider:) -> "no provider registered under " <> provider
    NoSecret(provider:, secret_name:) ->
      "secret "
      <> secret_name
      <> " for provider "
      <> provider
      <> " is not available"
  }
}

// --- pure incremental SSE parser ----------------------------------------

/// One parsed server-sent event, or a framing-level defect.
///
/// Constructor invariants: `SseMessage.event` is the `event:` field when
/// one was sent; `data` is the `data:` lines joined with `\n` per the SSE
/// specification; `SseMalformed` reports a framing-level defect — a line
/// that was not valid UTF-8, or a line that exceeded `max_line_bytes`
/// without a terminator — and consumers surface it as an in-band
/// failure, never a crash.
pub type SseEvent {
  /// A dispatched event.
  SseMessage(event: Option(String), data: String)

  /// A line that could not be decoded.
  SseMalformed(reason: String)
}

/// The maximum byte size of the carry buffer — the bytes of a single SSE
/// line still awaiting its terminator. Real provider frames top out well
/// under a megabyte (the largest are tool-argument fragments and base64
/// image payloads inside one `data:` line), so four mebibytes is
/// generous; a line that exceeds it without a terminator is not a
/// provider frame but a hostile or broken proxy, and the parser reports
/// it as a framing defect (`SseMalformed`) rather than buffering without
/// bound.
pub const max_line_bytes = 4_194_304

/// The maximum cumulative byte size of the `data:` fields retained for one SSE
/// event. A blank line normally dispatches those fields immediately; this
/// separate bound covers a peer which keeps sending terminated `data:` lines
/// but never sends that blank line.
pub const max_event_bytes = 4_194_304

/// The maximum number of `data:` fields retained for one SSE event. The byte
/// budget alone cannot bound an attacker sending empty fields, since each one
/// occupies a list cell but contributes almost nothing to the joined payload.
pub const max_event_data_lines = 4096

/// The maximum cumulative response-body bytes one successful attempt may feed
/// into its adapter. Sixteen MiB is far above Loom's configured model outputs,
/// while still bounding completed SSE events, comments, and small deltas across
/// the whole response rather than one frame at a time.
pub const max_response_bytes = 16_777_216

/// Incremental SSE parser state: pure data, so feeding is a fold. The
/// carry buffer holds bytes of an incomplete line (chunks may split lines
/// and even UTF-8 codepoints); the field buffers hold the in-progress
/// event awaiting its blank-line dispatch.
pub opaque type SseParser {
  /// Invariants: `carry` contains no complete line except possibly a
  /// trailing lone `\r` awaiting a potential `\n`, and never exceeds
  /// `max_line_bytes`; `data_bytes` is the joined byte size of `data_lines`
  /// and never exceeds `max_event_bytes`; `data_line_count` never exceeds
  /// `max_event_data_lines`; the first `scanned` bytes of `carry` are known to
  /// contain no line terminator, so re-feeding resumes past them and every byte
  /// is examined once; `data_lines` is in reverse arrival order.
  SseParser(
    carry: BitArray,
    scanned: Int,
    event_name: Option(String),
    data_lines: List(String),
    data_bytes: Int,
    data_line_count: Int,
  )
}

/// A fresh SSE parser with empty carry state.
///
/// ## Examples
///
/// ```gleam
/// let #(_parser, events) =
///   stream.feed(stream.new_parser(), <<"data: hi\n\n":utf8>>)
/// assert events == [stream.SseMessage(event: option.None, data: "hi")]
/// ```
///
pub fn new_parser() -> SseParser {
  SseParser(
    carry: <<>>,
    scanned: 0,
    event_name: None,
    data_lines: [],
    data_bytes: 0,
    data_line_count: 0,
  )
}

/// Feeds one chunk of bytes, returning the successor parser and the
/// events completed by this chunk. Chunk boundaries are invisible:
/// feeding a byte stream in any chunking yields the same events. Runs in
/// time linear in the chunk (each byte is scanned once, resuming past
/// the already-scanned carry prefix); if an unterminated line grows past
/// `max_line_bytes` the parser emits `SseMalformed`, discards the
/// buffered line, and stays usable — consumers settle the stream in-band
/// on the malformed event.
///
/// ## Examples
///
/// ```gleam
/// let #(parser, first) = stream.feed(stream.new_parser(), <<"data: h":utf8>>)
/// let #(_parser, second) = stream.feed(parser, <<"i\n\n":utf8>>)
/// assert first == []
///   && second == [stream.SseMessage(event: option.None, data: "hi")]
/// ```
///
pub fn feed(
  parser: SseParser,
  chunk: BitArray,
) -> #(SseParser, List(SseEvent)) {
  let buffer = bit_array.append(parser.carry, chunk)

  // `from` is the old carry's already-scanned prefix, still valid against
  // `buffer` because the new chunk is appended after it: scanning resumes
  // exactly there instead of re-examining bytes this or an earlier feed
  // already ruled out as terminator-free. carry/scanned are cleared here
  // since feed_loop will repopulate them (via NoTerminator) if this feed
  // ends mid-line.
  let from = parser.scanned
  let parser = SseParser(..parser, carry: <<>>, scanned: 0)
  feed_loop(parser, buffer, from, [])
}

fn feed_loop(
  parser: SseParser,
  buffer: BitArray,
  from: Int,
  reversed_events: List(SseEvent),
) -> #(SseParser, List(SseEvent)) {
  case take_line(buffer, from) {
    LineFound(line:, rest:) -> {
      let #(parser, new_events) = handle_line(parser, line)
      let reversed_events =
        list.fold(new_events, reversed_events, fn(accumulator, event) {
          [event, ..accumulator]
        })
      feed_loop(parser, rest, 0, reversed_events)
    }
    NoTerminator(scanned:) ->
      case bit_array.byte_size(buffer) > max_line_bytes {
        // The carry bound: an unterminated line this long is not a
        // provider frame. Report it and drop the buffer so memory stays
        // bounded no matter what the wire sends next.
        True -> #(
          SseParser(..parser, carry: <<>>, scanned: 0),
          list.reverse([
            SseMalformed(
              reason: "sse line exceeded "
              <> int.to_string(max_line_bytes)
              <> " bytes without a line terminator",
            ),
            ..reversed_events
          ]),
        )
        False -> #(
          SseParser(..parser, carry: buffer, scanned:),
          list.reverse(reversed_events),
        )
      }
  }
}

// The outcome of scanning the buffer for one line: a line split around
// its terminator, or the offset up to which no terminator exists (the
// resume point for the next feed, so no byte is scanned twice).
type LineScan {
  LineFound(line: BitArray, rest: BitArray)
  NoTerminator(scanned: Int)
}

// Finds the first line terminator (\n, \r\n, or lone \r) at or after
// `at` and splits the buffer around it. A trailing \r with nothing after
// it stays unscanned: the next chunk may begin with \n, and splitting
// early would make the result depend on chunk boundaries.
fn take_line(buffer: BitArray, at: Int) -> LineScan {
  case bit_array.slice(buffer, at, 1) {
    Ok(<<0x0A>>) ->
      LineFound(
        line: slice_or_empty(buffer, 0, at),
        rest: drop_bytes(buffer, at + 1),
      )
    Ok(<<0x0D>>) ->
      case bit_array.slice(buffer, at + 1, 1) {
        Ok(<<0x0A>>) ->
          LineFound(
            line: slice_or_empty(buffer, 0, at),
            rest: drop_bytes(buffer, at + 2),
          )
        Ok(_) ->
          LineFound(
            line: slice_or_empty(buffer, 0, at),
            rest: drop_bytes(buffer, at + 1),
          )

        // A lone trailing \r: wait for the next chunk, re-scanning from
        // the \r itself.
        Error(Nil) -> NoTerminator(scanned: at)
      }
    Ok(_) -> take_line(buffer, at + 1)
    Error(Nil) -> NoTerminator(scanned: at)
  }
}

fn slice_or_empty(buffer: BitArray, at: Int, take: Int) -> BitArray {
  case bit_array.slice(buffer, at, take) {
    Ok(bytes) -> bytes
    Error(Nil) -> <<>>
  }
}

fn drop_bytes(buffer: BitArray, count: Int) -> BitArray {
  slice_or_empty(buffer, count, bit_array.byte_size(buffer) - count)
}

// Processes one complete line per the SSE grammar: blank dispatches,
// `:` comments are dropped, `event:`/`data:` accumulate, and other
// fields (`id`, `retry`, unknown names) are ignored.
fn handle_line(
  parser: SseParser,
  line: BitArray,
) -> #(SseParser, List(SseEvent)) {
  case bit_array.to_string(line) {
    Error(Nil) -> #(reset_event(parser), [
      SseMalformed(reason: "sse line was not valid utf-8"),
    ])
    Ok("") -> dispatch(parser)
    Ok(":" <> _comment) -> #(parser, [])
    Ok("data: " <> value) | Ok("data:" <> value) -> add_data(parser, value)
    Ok("data") -> add_data(parser, "")
    Ok("event: " <> value) | Ok("event:" <> value) -> #(
      SseParser(..parser, event_name: Some(value)),
      [],
    )
    Ok("event") -> #(SseParser(..parser, event_name: Some("")), [])
    Ok(_other_field) -> #(parser, [])
  }
}

// Blank line: dispatch the buffered event. Per the SSE specification an
// event with an empty data buffer is discarded (its event name resets).
fn dispatch(parser: SseParser) -> #(SseParser, List(SseEvent)) {
  let reset = reset_event(parser)
  case parser.data_lines {
    [] -> #(reset, [])
    lines -> #(reset, [
      SseMessage(
        event: parser.event_name,
        data: string.join(list.reverse(lines), "\n"),
      ),
    ])
  }
}

// Retains one data field only while the cumulative event stays within its
// budget. Each later line contributes one newline because dispatch joins the
// fields with `\n`; counting the eventual value rather than list cells makes
// the invariant independent of how the wire chunks those lines.
fn add_data(parser: SseParser, value: String) -> #(SseParser, List(SseEvent)) {
  let separator = case parser.data_lines {
    [] -> 0
    [_, ..] -> 1
  }
  let data_bytes = parser.data_bytes + separator + string.byte_size(value)
  let data_line_count = parser.data_line_count + 1
  case data_bytes > max_event_bytes || data_line_count > max_event_data_lines {
    True -> #(reset_event(parser), [
      SseMalformed(reason: case data_line_count > max_event_data_lines {
        True ->
          "sse event exceeded "
          <> int.to_string(max_event_data_lines)
          <> " data fields before a blank-line terminator"
        False ->
          "sse event data exceeded "
          <> int.to_string(max_event_bytes)
          <> " bytes before a blank-line terminator"
      }),
    ])
    False -> #(
      SseParser(
        ..parser,
        data_lines: [value, ..parser.data_lines],
        data_bytes:,
        data_line_count:,
      ),
      [],
    )
  }
}

fn reset_event(parser: SseParser) -> SseParser {
  SseParser(
    ..parser,
    event_name: None,
    data_lines: [],
    data_bytes: 0,
    data_line_count: 0,
  )
}

// --- the response machine and process pump ------------------------------

/// An adapter's fold over the raw HTTP response: pure state transitions
/// producing `StreamEvent`s. `run` drives one of these on a process.
///
/// Constructor invariants: callbacks are pure; the machine emits at most
/// one terminal event (`Settled`/`Failed`) across a whole response —
/// `run` enforces the at-most-once delivery regardless; `on_end` and
/// `on_failure` return whatever events the response's end implies (for a
/// stream that already settled, nothing).
pub type ResponseMachine(state) {
  ResponseMachine(
    /// The state before any response bytes.
    init: state,
    /// Applied once when status and headers arrive.
    on_status: fn(state, Int, List(#(String, String))) -> state,
    /// Applied per body chunk.
    on_chunk: fn(state, BitArray) -> #(state, List(StreamEvent)),
    /// Applied when the body ends normally.
    on_end: fn(state) -> List(StreamEvent),
    /// Applied when the transport fails.
    on_failure: fn(state, String) -> List(StreamEvent),
  )
}

/// A provider stream: the subject on which `StreamEvent`s arrive, its
/// cancellation capability, and the process that remains alive until owned
/// external work has drained normally. An abnormal owner exit loses proof and
/// must be interpreted through `DrainOutcome` rather than as acknowledgement.
///
/// Constructor invariants: `events` is owned by the process that called
/// `gateway.request`, so only that process may receive from it. `owner` is
/// `Some` whenever the handle owns asynchronous work and that process exits
/// only after every descendant has stopped. `None` is reserved for an already
/// terminal or entirely local fixture with no work to drain.
pub type StreamHandle {
  StreamHandle(
    /// The single-consumer channel carrying ordered deltas and one terminal.
    events: Subject(StreamEvent),
    /// The idempotent capability which begins cooperative teardown.
    cancel: fn() -> Nil,
    /// The process whose normal exit acknowledges complete transitive teardown.
    owner: Option(Pid),
  )
}

/// What observing a stream owner established about its ownership tree.
///
/// Only `Drained` authorizes replacement work. `TimedOut` means the witness is
/// still alive; `ProofLost` means it died abnormally and can no longer certify
/// whether descendants remain.
pub type DrainOutcome {
  /// The owner exited normally and certified complete transitive teardown.
  Drained

  /// The observation deadline elapsed while the owner remained live.
  TimedOut

  /// The owner exited without the normal reason required to prove teardown.
  ProofLost
}

/// A one-shot observation of a stream owner's eventual exit.
///
/// Register this witness before starting asynchronous work when the exit
/// reason matters. A monitor installed after an owner has already exited can
/// report only `noproc`, which proves death but cannot prove clean drain.
pub opaque type DrainWitness {
  DrainWitness(owner: Option(Pid), monitor: Option(Monitor))
}

/// A provider stream whose owner exists while its work remains parked.
///
/// Callers publish `handle.owner` to their own custodian before invoking
/// `begin`. This makes crossing a composition boundary failure-atomic: if
/// publication is rejected, cancellation can retire the parked owner without
/// starting external work.
pub type PreparedStream {
  PreparedStream(
    /// The cancellable handle available before external work starts.
    handle: StreamHandle,
    /// The idempotent permit which lets the prepared request start.
    begin: fn() -> Nil,
  )
}

/// Starts a prepared stream and returns its already-published handle.
///
/// ## Examples
///
/// ```gleam
/// let handle = stream.start_prepared(prepared)
/// ```
///
pub fn start_prepared(prepared: PreparedStream) -> StreamHandle {
  prepared.begin()
  prepared.handle
}

/// Constructs a stream backed by asynchronous work whose owner is a drain
/// witness for the whole subtree.
///
/// Use this constructor whenever request work can outlive the function which
/// returns the handle. The owner must remain alive after terminal delivery
/// until every process, port, socket, and retry attempt beneath it has stopped.
///
/// ## Examples
///
/// ```gleam
/// let handle = stream.owned(events:, owner:, cancel: fn() {
///   process.send(stop, Nil)
/// })
/// // handle.owner == Some(owner)
/// ```
///
pub fn owned(
  events events: Subject(StreamEvent),
  cancel cancel: fn() -> Nil,
  owner owner: Pid,
) -> StreamHandle {
  StreamHandle(events:, cancel:, owner: Some(owner))
}

/// Constructs a stream with no asynchronous work to drain.
///
/// This is for an already-produced terminal or a local fixture whose
/// cancellation closure owns no process, port, or socket. A producer that
/// merely happens to be fast still uses `owned` if work can remain live.
///
/// ## Examples
///
/// ```gleam
/// let events = process.new_subject()
/// process.send(events, stream.Failed(error: stream.ProviderCancelled))
/// let handle = stream.immediate(events:, cancel: fn() { Nil })
/// assert stream.await_stopped(handle, within: 0) == stream.Drained
/// ```
///
pub fn immediate(
  events events: Subject(StreamEvent),
  cancel cancel: fn() -> Nil,
) -> StreamHandle {
  StreamHandle(events:, cancel:, owner: None)
}

/// Requests cancellation of the whole provider request. The request owner
/// decides the cancellation/terminal race and makes repeated calls harmless.
///
/// This function requests teardown; it does not acknowledge teardown. Use
/// `await_stopped` or monitor `handle.owner` when ordering later work depends
/// on the old request being gone.
///
/// ## Examples
///
/// ```gleam
/// stream.cancel(handle)
/// stream.cancel(handle)
/// // Repeated cancellation is harmless.
/// ```
///
pub fn cancel(handle: StreamHandle) -> Nil {
  handle.cancel()
}

/// Registers the monitor which will later adjudicate the owner's exit reason.
///
/// Call this before invoking a prepared stream's `begin` closure. Immediate
/// streams return an already-drained witness without allocating a monitor.
///
/// ## Examples
///
/// ```gleam
/// let stream.PreparedStream(handle:, begin:) = prepared
/// let witness = stream.watch_drain(handle)
/// begin()
/// // stream.await_drain_forever(witness)
/// ```
///
pub fn watch_drain(handle: StreamHandle) -> DrainWitness {
  case handle.owner {
    None -> DrainWitness(owner: None, monitor: None)
    Some(owner) ->
      DrainWitness(owner: Some(owner), monitor: Some(process.monitor(owner)))
  }
}

/// Waits up to `within` milliseconds on a previously registered witness.
///
/// A timeout leaves the monitor active so the same witness can be passed to
/// `await_drain_forever`. Call `release_drain` when abandoning it instead.
///
/// ## Examples
///
/// ```gleam
/// case stream.await_drain(witness, within: 2_000) {
///   stream.TimedOut -> stream.release_drain(witness)
///   stream.Drained | stream.ProofLost -> Nil
/// }
/// ```
///
pub fn await_drain(witness: DrainWitness, within timeout: Int) -> DrainOutcome {
  let DrainWitness(owner:, monitor:) = witness
  case owner, monitor {
    None, None -> Drained
    Some(_owner), Some(monitor) ->
      process.new_selector()
      |> process.select_specific_monitor(monitor, drain_outcome)
      |> process.selector_receive(timeout)
      |> result.unwrap(TimedOut)
    _, _ -> ProofLost
  }
}

/// Waits without a deadline on a previously registered drain witness.
///
/// The monitor is released after its original `Down` has been adjudicated.
///
/// ## Examples
///
/// ```gleam
/// let outcome = stream.await_drain_forever(witness)
/// // Only `stream.Drained` authorizes replacement work.
/// ```
///
pub fn await_drain_forever(witness: DrainWitness) -> DrainOutcome {
  let outcome = case witness {
    DrainWitness(owner: None, monitor: None) -> Drained
    DrainWitness(owner: Some(_owner), monitor: Some(monitor)) ->
      process.new_selector()
      |> process.select_specific_monitor(monitor, drain_outcome)
      |> process.selector_receive_forever()
    _ -> ProofLost
  }
  release_drain(witness)
  outcome
}

/// Releases a drain witness which will no longer be awaited.
///
/// ## Examples
///
/// ```gleam
/// stream.release_drain(witness)
/// ```
///
pub fn release_drain(witness: DrainWitness) -> Nil {
  case witness {
    DrainWitness(monitor: Some(monitor), ..) ->
      process.demonitor_process(monitor)
    DrainWitness(monitor: None, ..) -> Nil
  }
}

/// Waits up to `within` milliseconds for the stream's complete ownership tree
/// to drain. An immediate handle is already stopped.
///
/// `TimedOut` does not kill the owner. `ProofLost` is distinct because a dead
/// witness cannot be waited into certainty; neither outcome authorizes
/// replacement work. Use `watch_drain` before `begin` when the original exit
/// reason matters: a convenience helper called after exit can observe only
/// `noproc`, not recover whether that exit was normal.
///
/// ## Examples
///
/// ```gleam
/// stream.cancel(handle)
/// let outcome = stream.await_stopped(handle, within: 2_000)
/// // Only `stream.Drained` authorizes replacement work.
/// ```
///
pub fn await_stopped(
  handle: StreamHandle,
  within timeout: Int,
) -> DrainOutcome {
  let witness = watch_drain(handle)
  let outcome = await_drain(witness, within: timeout)
  case outcome {
    TimedOut -> release_drain(witness)
    Drained | ProofLost -> Nil
  }
  outcome
}

/// Waits until the stream's complete ownership tree has drained.
///
/// This is deliberately unbounded. Callers use it only at an ordering barrier
/// where proceeding beside unconfirmed old work would violate exclusivity.
/// Use `watch_drain` before `begin` when the original exit reason matters: a
/// convenience helper called after exit can observe only `noproc`.
///
/// ## Examples
///
/// ```gleam
/// stream.cancel(handle)
/// let outcome = stream.await_stopped_forever(handle)
/// // Replacement work may begin only when outcome is `stream.Drained`.
/// ```
///
pub fn await_stopped_forever(handle: StreamHandle) -> DrainOutcome {
  watch_drain(handle)
  |> await_drain_forever
}

fn drain_outcome(down: process.Down) -> DrainOutcome {
  case down {
    process.ProcessDown(reason:, ..) ->
      case reason {
        process.Normal -> Drained
        process.Killed | process.Abnormal(_) -> ProofLost
      }
    process.PortDown(..) -> ProofLost
  }
}

/// Receives the next stream event, `Error(Nil)` on timeout.
///
/// ## Examples
///
/// ```gleam
/// // stream.next(handle, within: 30_000)
/// // -> Ok(stream.Delta(stream.TextDelta(0, "Hello")))
/// ```
///
pub fn next(
  handle: StreamHandle,
  within timeout: Int,
) -> Result(StreamEvent, Nil) {
  process.receive(handle.events, within: timeout)
}

/// Collects deltas until the terminal event, returning both. `Error(Nil)`
/// if any single wait exceeds the timeout.
///
/// ## Examples
///
/// ```gleam
/// // stream.await_terminal(handle, within: 30_000)
/// // -> Ok(#([...deltas], stream.Settled(message, usage)))
/// ```
///
pub fn await_terminal(
  handle: StreamHandle,
  within timeout: Int,
) -> Result(#(List(Delta), StreamEvent), Nil) {
  await_terminal_loop(handle, timeout, [])
}

fn await_terminal_loop(
  handle: StreamHandle,
  timeout: Int,
  deltas: List(Delta),
) -> Result(#(List(Delta), StreamEvent), Nil) {
  case next(handle, within: timeout) {
    Ok(Delta(delta:)) -> await_terminal_loop(handle, timeout, [delta, ..deltas])
    Ok(terminal) -> Ok(#(list.reverse(deltas), terminal))
    Error(Nil) -> Error(Nil)
  }
}

/// Control messages accepted by the provider request owner. The subject is
/// created by that owner and captured by `StreamHandle.cancel`.
pub type Control {
  /// Requests cancellation of the current attempt.
  Cancel
}

/// The result of one routed provider attempt.
///
/// `AttemptTerminal` is eligible for ordinary fallback classification;
/// `AttemptCancelled` and `ConsumerGone` stop the whole route walk.
pub type AttemptOutcome {
  /// The provider produced the attempt's single terminal event.
  AttemptTerminal(terminal: StreamEvent)

  /// Cancellation was acknowledged before another terminal won the race.
  AttemptCancelled

  /// Cancellation began, but no terminal acknowledged it within the grace.
  AttemptCancellationUnconfirmed

  /// The transport owner died without proving its descendants drained.
  AttemptDrainProofLost

  /// The process which could consume deltas exited, so the attempt was drained.
  ConsumerGone
}

type AttemptEvent {
  Http(event: http.HttpEvent)
  Cancelled
  DeadlineExpired
  ConsumerExited(down: process.Down)
  TransportExited(down: process.Down)
}

/// Runs one request attempt to completion on the calling request-owner
/// process. It starts a monitorable transport, folds the response machine,
/// selects cancellation and consumer/transport death alongside HTTP events,
/// and returns one outcome to the fallback owner. `within` is one absolute
/// deadline for the whole attempt, not an idle timeout refreshed by chunks.
/// Every attempt gets a fresh HTTP subject, so late events from a cancelled
/// attempt cannot enter the next.
///
/// This is an internal fixture facade which does not publish the transport
/// owner. Production calls `run_tracked` so cancellation always retains that
/// ownership path.
///
/// ## Examples
///
/// ```gleam
/// // let outcome = stream.run(
/// //   transport, request, machine, deliver,
/// //   control: process.new_subject(),
/// //   consumer: process.self(),
/// //   within: 300_000,
/// // )
/// ```
///
@internal
pub fn run(
  transport: Transport,
  request: HttpRequest,
  machine: ResponseMachine(state),
  deliver: fn(Delta) -> Nil,
  control control: Subject(Control),
  consumer consumer: Pid,
  within timeout: Int,
) -> AttemptOutcome {
  run_tracked(
    transport,
    request,
    machine,
    deliver,
    fn(_running) { Nil },
    control:,
    consumer:,
    within: timeout,
  )
}

/// Runs one request attempt and publishes the live transport capability before
/// waiting on it. The gateway uses this to retain a cancellation path even if
/// its fallback pump crashes.
///
/// `started` is part of the ownership protocol, not an observation hook. The
/// prepared transport remains parked until that callback returns, so the
/// caller must publish its owner/cancel pair before returning from `started`.
///
/// ## Examples
///
/// ```gleam
/// stream.run_tracked(
///   transport,
///   request,
///   machine,
///   deliver,
///   fn(running) { publish_transport_owner(running) },
///   control: process.new_subject(),
///   consumer: process.self(),
///   within: 300_000,
/// )
/// // -> stream.AttemptTerminal(terminal)
/// ```
///
pub fn run_tracked(
  transport: Transport,
  request: HttpRequest,
  machine: ResponseMachine(state),
  deliver: fn(Delta) -> Nil,
  started: fn(http.RunningRequest) -> Nil,
  control control: Subject(Control),
  consumer consumer: Pid,
  within timeout: Int,
) -> AttemptOutcome {
  let http_events = process.new_subject()
  let http.Transport(prepare_streaming:) = transport
  case prepare_streaming(request, http_events) {
    Error(reason) -> {
      AttemptTerminal(Failed(TransportFailed("start failed: " <> reason)))
    }
    Ok(http.PreparedRequest(running:, begin:)) -> {
      // Publication precedes admission at the transport seam itself. There is
      // no wrapper process whose begin handler can create untracked work.
      started(running)
      let consumer_monitor = process.monitor(consumer)
      let transport_monitor = process.monitor(http.owner(running))
      let deadline = process.new_subject()
      let deadline_timer =
        process.send_after(deadline, int.max(timeout, 0), Nil)
      begin()
      let selector =
        process.new_selector()
        |> process.select_map(http_events, Http)
        |> process.select_map(control, fn(_cancel) { Cancelled })
        |> process.select_map(deadline, fn(_nil) { DeadlineExpired })
        |> process.select_specific_monitor(consumer_monitor, ConsumerExited)
        |> process.select_specific_monitor(transport_monitor, TransportExited)
      run_loop(
        selector,
        running,
        consumer_monitor,
        transport_monitor,
        deadline_timer,
        machine,
        machine.init,
        deliver,
        response_bytes: 0,
      )
    }
  }
}

fn run_loop(
  selector: Selector(AttemptEvent),
  running: http.RunningRequest,
  consumer_monitor: Monitor,
  transport_monitor: Monitor,
  deadline_timer: Timer,
  machine: ResponseMachine(state),
  state: state,
  deliver: fn(Delta) -> Nil,
  response_bytes response_bytes: Int,
) -> AttemptOutcome {
  case process.selector_receive_forever(selector) {
    DeadlineExpired ->
      finish_outcome(
        deadline_timer,
        case stop_attempt(running, consumer_monitor, transport_monitor) {
          Drained ->
            AttemptTerminal(
              Failed(TransportFailed(
                reason: "timed out waiting for the provider",
              )),
            )
          TimedOut -> AttemptCancellationUnconfirmed
          ProofLost -> AttemptDrainProofLost
        },
      )
    Cancelled ->
      finish_outcome(
        deadline_timer,
        case stop_attempt(running, consumer_monitor, transport_monitor) {
          Drained -> AttemptCancelled
          TimedOut -> AttemptCancellationUnconfirmed
          ProofLost -> AttemptDrainProofLost
        },
      )
    ConsumerExited(down: _) -> {
      let _stopped = stop_attempt(running, consumer_monitor, transport_monitor)
      finish_outcome(deadline_timer, ConsumerGone)
    }
    TransportExited(down:) -> {
      process.demonitor_process(consumer_monitor)
      process.demonitor_process(transport_monitor)
      finish_outcome(deadline_timer, case drain_outcome(down) {
        Drained ->
          AttemptTerminal(
            Failed(TransportFailed(
              reason: "provider transport stopped before a terminal response",
            )),
          )
        TimedOut -> AttemptCancellationUnconfirmed
        ProofLost -> AttemptDrainProofLost
      })
    }
    Http(http.ResponseStatus(status:, headers:)) ->
      run_loop(
        selector,
        running,
        consumer_monitor,
        transport_monitor,
        deadline_timer,
        machine,
        machine.on_status(state, status, headers),
        deliver,
        response_bytes:,
      )
    Http(http.ResponseChunk(chunk:)) ->
      run_chunk(
        selector,
        running,
        consumer_monitor,
        transport_monitor,
        deadline_timer,
        machine,
        state,
        deliver,
        response_bytes:,
        chunk:,
      )
    Http(http.ResponseEnd) -> {
      // A well-behaved machine's on_end always yields a terminal once the
      // status is known; None here means the body ended before the
      // adapter ever saw enough to settle (e.g. status never arrived),
      // which is itself a disconnection, not a silent success.
      let terminal = case forward(machine.on_end(state), deliver) {
        Some(terminal) -> terminal
        None ->
          Failed(StreamDisconnected(context: "response ended without settling"))
      }
      finish_outcome(
        deadline_timer,
        case finish_attempt(consumer_monitor, transport_monitor) {
          Drained -> AttemptTerminal(terminal)
          TimedOut -> AttemptCancellationUnconfirmed
          ProofLost -> AttemptDrainProofLost
        },
      )
    }
    Http(http.RequestFailed(reason:)) -> {
      // Mirrors on_end: a machine that has already settled (acc.done)
      // answers with no events, so this default only fires pre-settlement.
      let terminal = case forward(machine.on_failure(state, reason), deliver) {
        Some(terminal) -> terminal
        None -> Failed(TransportFailed(reason:))
      }
      finish_outcome(
        deadline_timer,
        case finish_attempt(consumer_monitor, transport_monitor) {
          Drained -> AttemptTerminal(terminal)
          TimedOut -> AttemptCancellationUnconfirmed
          ProofLost -> AttemptDrainProofLost
        },
      )
    }
  }
}

// Keep the chunk transition outside the selector dispatch so the three
// decisions remain visible: enforce the whole-response budget, ask the pure
// adapter to fold the chunk, then either drain on terminal or retain the same
// deadline while waiting for more input.
fn run_chunk(
  selector: Selector(AttemptEvent),
  running: http.RunningRequest,
  consumer_monitor: Monitor,
  transport_monitor: Monitor,
  deadline_timer: Timer,
  machine: ResponseMachine(state),
  state: state,
  deliver: fn(Delta) -> Nil,
  response_bytes response_bytes: Int,
  chunk chunk: BitArray,
) -> AttemptOutcome {
  let response_bytes = response_bytes + bit_array.byte_size(chunk)
  case response_bytes > max_response_bytes {
    True ->
      finish_outcome(
        deadline_timer,
        case stop_attempt(running, consumer_monitor, transport_monitor) {
          Drained -> AttemptTerminal(response_too_large())
          TimedOut -> AttemptCancellationUnconfirmed
          ProofLost -> AttemptDrainProofLost
        },
      )
    False -> {
      let #(state, events) = machine.on_chunk(state, chunk)
      case forward(events, deliver) {
        Some(terminal) ->
          finish_outcome(
            deadline_timer,
            case stop_attempt(running, consumer_monitor, transport_monitor) {
              Drained -> AttemptTerminal(terminal)
              TimedOut -> AttemptCancellationUnconfirmed
              ProofLost -> AttemptDrainProofLost
            },
          )
        None ->
          run_loop(
            selector,
            running,
            consumer_monitor,
            transport_monitor,
            deadline_timer,
            machine,
            state,
            deliver,
            response_bytes:,
          )
      }
    }
  }
}

fn response_too_large() -> StreamEvent {
  Failed(
    MalformedStream(corruption.report(
      at: "provider/stream.run",
      on: "response body",
      expected: "at most " <> int.to_string(max_response_bytes) <> " bytes",
      context: "provider response exceeded its cumulative byte budget",
    )),
  )
}

// Retire the one-shot deadline whenever any other terminal wins. Without this
// cancellation, a fallback walk would retain one stale timer message per
// completed attempt in the pump mailbox until the whole request ended.
fn finish_outcome(timer: Timer, outcome: AttemptOutcome) -> AttemptOutcome {
  let _cancelled = process.cancel_timer(timer)
  outcome
}

// Cancels live transport work before forgetting either monitor. Cancellation
// is silent at this layer: the gateway owner alone chooses the public terminal.
fn stop_attempt(
  running: http.RunningRequest,
  consumer_monitor: Monitor,
  transport_monitor: Monitor,
) -> DrainOutcome {
  http.cancel(running)
  let outcome =
    process.new_selector()
    |> process.select_specific_monitor(transport_monitor, drain_outcome)
    |> process.selector_receive(100)
    |> result.unwrap(TimedOut)
  release_attempt_monitors(consumer_monitor, transport_monitor)
  outcome
}

// A transport terminal is a message, not proof its owner stopped. Unlike an
// explicit cancellation, normal completion has no reporting grace which can
// replace a valid provider result. The attempt therefore remains at this
// ordering barrier until the already-installed monitor reports the real exit.
fn finish_attempt(
  consumer_monitor: Monitor,
  transport_monitor: Monitor,
) -> DrainOutcome {
  let outcome =
    process.new_selector()
    |> process.select_specific_monitor(transport_monitor, drain_outcome)
    |> process.selector_receive_forever()
  release_attempt_monitors(consumer_monitor, transport_monitor)
  outcome
}

fn release_attempt_monitors(
  consumer_monitor: Monitor,
  transport_monitor: Monitor,
) -> Nil {
  process.demonitor_process(consumer_monitor)
  process.demonitor_process(transport_monitor)
}

// Delivers deltas in order and returns the first terminal event, dropping
// anything a buggy machine might emit after it.
fn forward(
  events: List(StreamEvent),
  deliver: fn(Delta) -> Nil,
) -> Option(StreamEvent) {
  case events {
    [] -> None
    [Delta(delta:), ..rest] -> {
      deliver(delta)
      forward(rest, deliver)
    }
    [terminal, ..] -> Some(terminal)
  }
}
