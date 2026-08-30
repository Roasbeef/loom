//// The HTTP transport seam.
////
//// The gateway and adapters never talk to a socket directly: they hand a
//// `HttpRequest` to an injected `Transport`, which delivers the response
//// as a stream of `HttpEvent` messages to a subject. Tests inject a
//// transport that replays fixture events; production wires the Erlang
//// `httpc` streaming shim via `httpc_transport`. The native owner is both the
//// raw-message receiver and the published drain witness. It captures the
//// request's dedicated handler before forwarding events and does not exit
//// until that handler has stopped. Parsing and response folds above the
//// `HttpEvent` boundary retain the sans-io shape from the style guide.
////
//// Secrets (API keys) appear only inside `HttpRequest.headers`, which
//// flows exclusively into the transport. No `HttpEvent`, error, or stream
//// event ever carries the request back out (spec §3.3 invariant 4).

import gleam/erlang/process.{type Pid, type Subject}
import provider/internal/ffi_httpc

/// One outbound HTTP request, fully built.
///
/// Constructor invariants: `method` is an uppercase HTTP method; `url` is
/// absolute; `headers` may carry credentials and must therefore never be
/// copied into any returned, logged, or persisted structure; `body` is the
/// UTF-8 request payload (empty for bodyless methods).
pub type HttpRequest {
  HttpRequest(
    method: String,
    url: String,
    headers: List(#(String, String)),
    body: String,
  )
}

/// One event in a streamed HTTP response, delivered in order: exactly one
/// `ResponseStatus`, then zero or more `ResponseChunk`s, then exactly one
/// `ResponseEnd` — or a single `RequestFailed` at any point, which
/// terminates the stream.
///
/// Constructor invariants: `ResponseStatus.headers` are lowercase-named
/// response headers; `ResponseChunk.chunk` is a raw body fragment split at
/// arbitrary byte boundaries; `RequestFailed.reason` is a human-readable
/// transport diagnostic that never contains request headers.
pub type HttpEvent {
  /// The response status line and headers arrived.
  ResponseStatus(status: Int, headers: List(#(String, String)))
  /// A fragment of the response body arrived.
  ResponseChunk(chunk: BitArray)
  /// The response body ended normally.
  ResponseEnd
  /// The transport failed before the response completed.
  RequestFailed(reason: String)
}

/// One live transport request. The process is the sole sender of this
/// request's `HttpEvent`s and is monitorable by the provider request owner;
/// `cancel` stops the underlying request and is safe after completion.
///
/// Constructor invariants: `owner` retains whatever transport-native request
/// identity cancellation needs and remains alive until that work has stopped.
/// `cancel` signals that owner and is safe during native startup. Callers must
/// not kill the owner: its lifetime is the drain acknowledgement.
pub type RunningRequest {
  RunningRequest(
    /// The process whose exit proves the native request and handler stopped.
    owner: Pid,
    /// The idempotent capability which asks that owner to tear down the request.
    cancel: fn() -> Nil,
  )
}

/// A transport request whose drain witness exists before network work starts.
///
/// The caller must publish `running.owner` to its own failure boundary before
/// invoking `begin`. Cancellation is valid on the parked request and prevents
/// a later begin from opening a socket.
pub type PreparedRequest {
  PreparedRequest(
    /// The request capability which is safe to publish immediately.
    running: RunningRequest,
    /// The one-way permit which admits transport work after publication.
    begin: fn() -> Nil,
  )
}

/// Cancels a live transport request. Repeated calls and calls after transport
/// completion are harmless.
///
/// Cancellation is a request, not a drain acknowledgement. Monitor
/// `http.owner(request)` when subsequent work must wait for the native socket.
///
/// ## Examples
///
/// ```gleam
/// http.cancel(request)
/// http.cancel(request)
/// // Both calls address the same native request.
/// ```
///
pub fn cancel(request: RunningRequest) -> Nil {
  request.cancel()
}

/// Returns the process whose exit acknowledges transport teardown.
///
/// The owner may outlive terminal response delivery while the receiver and
/// native handler finish closing. Callers monitor it; they do not kill it.
///
/// ## Examples
///
/// ```gleam
/// let monitor = process.monitor(http.owner(request))
/// // The monitor fires after the transport subtree drains.
/// ```
///
pub fn owner(request: RunningRequest) -> Pid {
  request.owner
}

/// A streaming HTTP transport as a record of functions, so tests can
/// inject fixtures and production can inject `httpc_transport`.
///
/// Constructor invariants: `prepare_streaming` returns a parked, monitorable
/// owner without starting external work. Cancellation before `begin` prevents
/// startup; cancellation during startup remains queued until the native
/// request identity is known. `RunningRequest.owner` is the sole sender of
/// response events, delivers them in contract order, and either delivers a terminal
/// `ResponseEnd`/`RequestFailed` before exiting or exits so its monitor reports
/// transport death.
pub type Transport {
  Transport(
    /// Prepares one parked request without admitting external work.
    prepare_streaming: fn(HttpRequest, Subject(HttpEvent)) ->
      Result(PreparedRequest, String),
  )
}

/// The production transport: Erlang `httpc` in asynchronous streaming
/// mode, wrapped so chunks arrive as `HttpEvent` messages on the subject.
/// The native owner is allocated while parked, then receives its begin permit
/// only after its PID exists as the returned drain witness. It captures and
/// monitors the dedicated OTP handler before forwarding any event, so a shared
/// manager restart cannot erase the socket witness. The FFI is limited to the
/// raw `httpc` mailbox and native teardown which Gleam cannot express;
/// response folding, timeout policy, retries, and terminal arbitration remain
/// in typed Gleam.
///
/// ## Examples
///
/// ```gleam
/// let transport = http.httpc_transport()
/// // stream.run(transport, request, machine, ...)
/// ```
///
pub fn httpc_transport() -> Transport {
  Transport(prepare_streaming: fn(request, subject) {
    start_httpc(request, subject)
  })
}

fn start_httpc(
  request: HttpRequest,
  subject: Subject(HttpEvent),
) -> Result(PreparedRequest, String) {
  let owner =
    ffi_httpc.prepare_stream_request(
      fn(status, headers) {
        process.send(subject, ResponseStatus(status:, headers:))
      },
      fn(chunk) { process.send(subject, ResponseChunk(chunk:)) },
      fn() { process.send(subject, ResponseEnd) },
      fn(reason) { process.send(subject, RequestFailed(reason:)) },
    )
  Ok(
    PreparedRequest(
      running: RunningRequest(owner:, cancel: fn() {
        ffi_httpc.cancel_stream_request(owner)
      }),
      begin: fn() {
        ffi_httpc.begin_stream_request(
          owner,
          request.method,
          request.url,
          request.headers,
          request.body,
        )
      },
    ),
  )
}
