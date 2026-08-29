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
////   `max_line_bytes`, and every byte is scanned exactly once, so a
////   hostile or broken proxy streaming a terminator-less line cannot
////   exhaust memory or drive quadratic re-scans — the stream fails
////   in-band as a framing defect instead.
//// - Adapters compose the parser with their own pure accumulator into a
////   `ResponseMachine` — a fold over `HttpEvent`s producing
////   `StreamEvent`s.
//// - `run` is the only impure piece: it starts the injected transport,
////   folds the machine over the received chunks, forwards deltas as they
////   appear, and returns the single terminal event.
////
//// Consumption contract for `StreamHandle` (what WP-E relies on): the
//// subject delivers zero or more `Delta` events followed by exactly one
//// terminal event — `Settled` or `Failed` — and nothing after it. Deltas
//// are ephemeral display data and never prove anything about settlement.

import core/corruption.{type CorruptionReport}
import core/message.{type AgentMessage, type Usage, AssistantMessage, Pending}
import gleam/bit_array
import gleam/erlang/process.{type Monitor, type Pid, type Selector, type Subject}
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

/// Incremental SSE parser state: pure data, so feeding is a fold. The
/// carry buffer holds bytes of an incomplete line (chunks may split lines
/// and even UTF-8 codepoints); the field buffers hold the in-progress
/// event awaiting its blank-line dispatch.
pub opaque type SseParser {
  /// Invariants: `carry` contains no complete line except possibly a
  /// trailing lone `\r` awaiting a potential `\n`, and never exceeds
  /// `max_line_bytes`; the first `scanned` bytes of `carry` are known to
  /// contain no line terminator, so re-feeding resumes past them and
  /// every byte is examined once; `data_lines` is in reverse arrival
  /// order.
  SseParser(
    carry: BitArray,
    scanned: Int,
    event_name: Option(String),
    data_lines: List(String),
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
  SseParser(carry: <<>>, scanned: 0, event_name: None, data_lines: [])
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
  events: List(SseEvent),
) -> #(SseParser, List(SseEvent)) {
  case take_line(buffer, from) {
    LineFound(line:, rest:) -> {
      let #(parser, new_events) = handle_line(parser, line)
      feed_loop(parser, rest, 0, list.append(events, new_events))
    }
    NoTerminator(scanned:) ->
      case bit_array.byte_size(buffer) > max_line_bytes {
        // The carry bound: an unterminated line this long is not a
        // provider frame. Report it and drop the buffer so memory stays
        // bounded no matter what the wire sends next.
        True -> #(
          SseParser(..parser, carry: <<>>, scanned: 0),
          list.append(events, [
            SseMalformed(
              reason: "sse line exceeded "
              <> int.to_string(max_line_bytes)
              <> " bytes without a line terminator",
            ),
          ]),
        )
        False -> #(SseParser(..parser, carry: buffer, scanned:), events)
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
    Error(Nil) -> #(parser, [
      SseMalformed(reason: "sse line was not valid utf-8"),
    ])
    Ok("") -> dispatch(parser)
    Ok(":" <> _comment) -> #(parser, [])
    Ok("data: " <> value) | Ok("data:" <> value) -> #(
      SseParser(..parser, data_lines: [value, ..parser.data_lines]),
      [],
    )
    Ok("data") -> #(
      SseParser(..parser, data_lines: ["", ..parser.data_lines]),
      [],
    )
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
  let reset = SseParser(..parser, event_name: None, data_lines: [])
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
/// external work has drained.
///
/// Constructor invariants: `events` is owned by the process that called
/// `gateway.request`, so only that process may receive from it. `owner` is
/// `Some` whenever the handle owns asynchronous work and that process exits
/// only after every descendant has stopped. `None` is reserved for an already
/// terminal or entirely local fixture with no work to drain.
pub type StreamHandle {
  StreamHandle(
    events: Subject(StreamEvent),
    cancel: fn() -> Nil,
    owner: Option(Pid),
  )
}

/// Constructs a stream backed by asynchronous work whose owner is a drain
/// witness for the whole subtree.
pub fn owned(
  events events: Subject(StreamEvent),
  cancel cancel: fn() -> Nil,
  owner owner: Pid,
) -> StreamHandle {
  StreamHandle(events:, cancel:, owner: Some(owner))
}

/// Constructs a stream with no asynchronous work to drain.
pub fn immediate(
  events events: Subject(StreamEvent),
  cancel cancel: fn() -> Nil,
) -> StreamHandle {
  StreamHandle(events:, cancel:, owner: None)
}

/// Requests cancellation of the whole provider request. The request owner
/// decides the cancellation/terminal race and makes repeated calls harmless.
pub fn cancel(handle: StreamHandle) -> Nil {
  handle.cancel()
}

/// Waits up to `within` milliseconds for the stream's complete ownership tree
/// to drain. An immediate handle is already stopped.
pub fn await_stopped(handle: StreamHandle, within timeout: Int) -> Bool {
  case handle.owner {
    None -> True
    Some(owner) -> {
      let monitor = process.monitor(owner)
      let stopped =
        process.new_selector()
        |> process.select_specific_monitor(monitor, fn(_down) { True })
        |> process.selector_receive(timeout)
        |> result.unwrap(False)
      process.demonitor_process(monitor)
      stopped
    }
  }
}

/// Waits until the stream's complete ownership tree has drained.
pub fn await_stopped_forever(handle: StreamHandle) -> Nil {
  case handle.owner {
    None -> Nil
    Some(owner) -> {
      let monitor = process.monitor(owner)
      let _down =
        process.new_selector()
        |> process.select_specific_monitor(monitor, fn(_down) { Nil })
        |> process.selector_receive_forever()
      Nil
    }
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
  Cancel
}

/// The result of one routed provider attempt.
///
/// `AttemptTerminal` is eligible for ordinary fallback classification;
/// `AttemptCancelled` and `ConsumerGone` stop the whole route walk.
pub type AttemptOutcome {
  AttemptTerminal(terminal: StreamEvent)
  AttemptCancelled
  AttemptCancellationUnconfirmed
  ConsumerGone
}

type AttemptEvent {
  Http(event: http.HttpEvent)
  Cancelled
  ConsumerExited(down: process.Down)
  TransportExited(down: process.Down)
}

type PreparedControl {
  BeginPrepared
  CancelPrepared
}

type PreparedEvent {
  PreparedControl(PreparedControl)
  PreparedHttp(http.HttpEvent)
  PreparedParentExited(process.Down)
  PreparedTransportExited(process.Down)
}

type PreparedRequest {
  PreparedRequest(running: http.RunningRequest, begin: fn() -> Nil)
}

/// Runs one request attempt to completion on the calling request-owner
/// process. It starts a monitorable transport, folds the response machine,
/// selects cancellation and consumer/transport death alongside HTTP events,
/// and returns one outcome to the fallback owner. Every attempt gets a fresh
/// HTTP subject, so late events from a cancelled attempt cannot enter the next.
///
/// The gateway calls this from its pump process; tests can call it
/// directly with a fixture transport.
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
  let PreparedRequest(running:, begin:) =
    prepare_request(transport, request, http_events)
  started(running)
  begin()
  let consumer_monitor = process.monitor(consumer)
  let transport_monitor = process.monitor(http.owner(running))
  let selector =
    process.new_selector()
    |> process.select_map(http_events, Http)
    |> process.select_map(control, fn(_cancel) { Cancelled })
    |> process.select_specific_monitor(consumer_monitor, ConsumerExited)
    |> process.select_specific_monitor(transport_monitor, TransportExited)
  run_loop(
    selector,
    running,
    consumer_monitor,
    transport_monitor,
    machine,
    machine.init,
    deliver,
    timeout,
  )
}

// The prepared custodian closes the otherwise unavoidable gap between an
// injected transport creating work and the gateway retaining its cancellation
// capability. `started` runs while this process is still parked before
// `BeginPrepared`, so a pump fault cannot lose either the custodian or work
// beneath it. The custodian is also the sole sender on `events` and exits only
// after the injected transport owner exits.
fn prepare_request(
  transport: Transport,
  request: HttpRequest,
  events: Subject(http.HttpEvent),
) -> PreparedRequest {
  let parent = process.self()
  let ready = process.new_subject()
  let owner =
    process.spawn_unlinked(fn() {
      let control = process.new_subject()
      process.send(ready, control)
      let parent_monitor = process.monitor(parent)
      await_prepared_start(transport, request, events, control, parent_monitor)
    })
  let control = process.receive_forever(ready)
  PreparedRequest(
    running: http.RunningRequest(owner:, cancel: fn() {
      process.send(control, CancelPrepared)
    }),
    begin: fn() { process.send(control, BeginPrepared) },
  )
}

fn await_prepared_start(
  transport: Transport,
  request: HttpRequest,
  events: Subject(http.HttpEvent),
  control: Subject(PreparedControl),
  parent_monitor: Monitor,
) -> Nil {
  let selector =
    process.new_selector()
    |> process.select_map(control, PreparedControl)
    |> process.select_specific_monitor(parent_monitor, PreparedParentExited)
  case process.selector_receive_forever(selector) {
    PreparedControl(BeginPrepared) ->
      start_prepared_transport(
        transport,
        request,
        events,
        control,
        parent_monitor,
      )
    PreparedControl(CancelPrepared) | PreparedParentExited(_down) ->
      process.demonitor_process(parent_monitor)
    PreparedHttp(_) | PreparedTransportExited(_) ->
      await_prepared_start(transport, request, events, control, parent_monitor)
  }
}

fn start_prepared_transport(
  transport: Transport,
  request: HttpRequest,
  events: Subject(http.HttpEvent),
  control: Subject(PreparedControl),
  parent_monitor: Monitor,
) -> Nil {
  let inner_events = process.new_subject()
  let http.Transport(start_streaming:) = transport
  case start_streaming(request, inner_events) {
    Error(reason) -> {
      process.send(events, http.RequestFailed("start failed: " <> reason))
      process.demonitor_process(parent_monitor)
    }
    Ok(running) -> {
      let transport_monitor = process.monitor(http.owner(running))
      own_prepared_transport(
        running,
        events,
        inner_events,
        control,
        parent_monitor,
        transport_monitor,
      )
    }
  }
}

fn own_prepared_transport(
  running: http.RunningRequest,
  events: Subject(http.HttpEvent),
  inner_events: Subject(http.HttpEvent),
  control: Subject(PreparedControl),
  parent_monitor: Monitor,
  transport_monitor: Monitor,
) -> Nil {
  let selector =
    process.new_selector()
    |> process.select_map(inner_events, PreparedHttp)
    |> process.select_map(control, PreparedControl)
    |> process.select_specific_monitor(parent_monitor, PreparedParentExited)
    |> process.select_specific_monitor(
      transport_monitor,
      PreparedTransportExited,
    )
  case process.selector_receive_forever(selector) {
    PreparedControl(CancelPrepared) | PreparedParentExited(_down) -> {
      http.cancel(running)
      await_prepared_transport(running, transport_monitor)
      forget_prepared(parent_monitor, transport_monitor)
    }
    PreparedControl(BeginPrepared) ->
      own_prepared_transport(
        running,
        events,
        inner_events,
        control,
        parent_monitor,
        transport_monitor,
      )
    PreparedTransportExited(_down) -> {
      process.send(
        events,
        http.RequestFailed(
          "provider transport stopped before a terminal response",
        ),
      )
      forget_prepared(parent_monitor, transport_monitor)
    }
    PreparedHttp(event) -> {
      process.send(events, event)
      case event {
        http.ResponseStatus(..) | http.ResponseChunk(..) ->
          own_prepared_transport(
            running,
            events,
            inner_events,
            control,
            parent_monitor,
            transport_monitor,
          )
        http.ResponseEnd | http.RequestFailed(..) -> {
          await_prepared_transport(running, transport_monitor)
          forget_prepared(parent_monitor, transport_monitor)
        }
      }
    }
  }
}

fn await_prepared_transport(
  running: http.RunningRequest,
  monitor: Monitor,
) -> Nil {
  case process.is_alive(http.owner(running)) {
    False -> Nil
    True -> {
      let _down =
        process.new_selector()
        |> process.select_specific_monitor(monitor, fn(_down) { Nil })
        |> process.selector_receive_forever()
      Nil
    }
  }
}

fn forget_prepared(parent_monitor: Monitor, transport_monitor: Monitor) -> Nil {
  process.demonitor_process(parent_monitor)
  process.demonitor_process(transport_monitor)
}

fn run_loop(
  selector: Selector(AttemptEvent),
  running: http.RunningRequest,
  consumer_monitor: Monitor,
  transport_monitor: Monitor,
  machine: ResponseMachine(state),
  state: state,
  deliver: fn(Delta) -> Nil,
  timeout: Int,
) -> AttemptOutcome {
  case process.selector_receive(selector, timeout) {
    Error(Nil) -> {
      case stop_attempt(running, consumer_monitor, transport_monitor) {
        True ->
          AttemptTerminal(
            Failed(TransportFailed(reason: "timed out waiting for the provider")),
          )
        False -> AttemptCancellationUnconfirmed
      }
    }
    Ok(Cancelled) ->
      case stop_attempt(running, consumer_monitor, transport_monitor) {
        True -> AttemptCancelled
        False -> AttemptCancellationUnconfirmed
      }
    Ok(ConsumerExited(down: _)) -> {
      let _stopped = stop_attempt(running, consumer_monitor, transport_monitor)
      ConsumerGone
    }
    Ok(TransportExited(down: _)) -> {
      let _stopped = stop_attempt(running, consumer_monitor, transport_monitor)
      AttemptTerminal(
        Failed(TransportFailed(
          reason: "provider transport stopped before a terminal response",
        )),
      )
    }
    Ok(Http(http.ResponseStatus(status:, headers:))) ->
      run_loop(
        selector,
        running,
        consumer_monitor,
        transport_monitor,
        machine,
        machine.on_status(state, status, headers),
        deliver,
        timeout,
      )
    Ok(Http(http.ResponseChunk(chunk:))) -> {
      let #(state, events) = machine.on_chunk(state, chunk)
      case forward(events, deliver) {
        Some(terminal) -> {
          case stop_attempt(running, consumer_monitor, transport_monitor) {
            True -> AttemptTerminal(terminal)
            False -> AttemptCancellationUnconfirmed
          }
        }
        None ->
          run_loop(
            selector,
            running,
            consumer_monitor,
            transport_monitor,
            machine,
            state,
            deliver,
            timeout,
          )
      }
    }
    Ok(Http(http.ResponseEnd)) -> {
      // A well-behaved machine's on_end always yields a terminal once the
      // status is known; None here means the body ended before the
      // adapter ever saw enough to settle (e.g. status never arrived),
      // which is itself a disconnection, not a silent success.
      let terminal = case forward(machine.on_end(state), deliver) {
        Some(terminal) -> terminal
        None ->
          Failed(StreamDisconnected(context: "response ended without settling"))
      }
      case finish_attempt(running, consumer_monitor, transport_monitor) {
        True -> AttemptTerminal(terminal)
        False -> AttemptCancellationUnconfirmed
      }
    }
    Ok(Http(http.RequestFailed(reason:))) -> {
      // Mirrors on_end: a machine that has already settled (acc.done)
      // answers with no events, so this default only fires pre-settlement.
      let terminal = case forward(machine.on_failure(state, reason), deliver) {
        Some(terminal) -> terminal
        None -> Failed(TransportFailed(reason:))
      }
      case finish_attempt(running, consumer_monitor, transport_monitor) {
        True -> AttemptTerminal(terminal)
        False -> AttemptCancellationUnconfirmed
      }
    }
  }
}

// Cancels live transport work before forgetting either monitor. Cancellation
// is silent at this layer: the gateway owner alone chooses the public terminal.
fn stop_attempt(
  running: http.RunningRequest,
  consumer_monitor: Monitor,
  transport_monitor: Monitor,
) -> Bool {
  http.cancel(running)
  finish_attempt(running, consumer_monitor, transport_monitor)
}

// A transport terminal is a message, not proof its owner stopped. This bounded
// observation decides whether a retry is safe; the gateway retains the live
// capability and remains the transitive drain witness when it is not.
fn finish_attempt(
  running: http.RunningRequest,
  consumer_monitor: Monitor,
  transport_monitor: Monitor,
) -> Bool {
  let stopped = case process.is_alive(http.owner(running)) {
    False -> True
    True -> {
      process.new_selector()
      |> process.select_specific_monitor(transport_monitor, fn(_down) { True })
      |> process.selector_receive(100)
      |> result.unwrap(False)
    }
  }
  process.demonitor_process(consumer_monitor)
  process.demonitor_process(transport_monitor)
  stopped
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
