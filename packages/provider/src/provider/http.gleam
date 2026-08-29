//// The HTTP transport seam.
////
//// The gateway and adapters never talk to a socket directly: they hand a
//// `HttpRequest` to an injected `Transport`, which delivers the response
//// as a stream of `HttpEvent` messages to a subject. Tests inject a
//// transport that replays fixture events; production wires the Erlang
//// `httpc` streaming shim via `httpc_transport`. Everything above the raw
//// chunk stream is pure Gleam — the sans-io pattern from the style guide.
////
//// Secrets (API keys) appear only inside `HttpRequest.headers`, which
//// flows exclusively into the transport. No `HttpEvent`, error, or stream
//// event ever carries the request back out (spec §3.3 invariant 4).

import gleam/erlang/process.{type Pid, type Subject}
import gleam/result
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
/// identity cancellation needs. For the production transport that is the
/// exact OTP `httpc` request id. `cancel` returns within a short fixed bound;
/// the provider owner separately observes and, if necessary, kills `owner`.
pub type RunningRequest {
  RunningRequest(owner: Pid, cancel: fn() -> Nil)
}

/// Cancels a live transport request. Repeated calls and calls after transport
/// completion are harmless.
pub fn cancel(request: RunningRequest) -> Nil {
  request.cancel()
}

/// The monitorable process that owns the live transport request.
pub fn owner(request: RunningRequest) -> Pid {
  request.owner
}

/// A streaming HTTP transport as a record of functions, so tests can
/// inject fixtures and production can inject `httpc_transport`.
///
/// Constructor invariants: `start_streaming` returns a monitorable owner
/// without waiting for response completion. Cancellation sent while the native
/// request starts must remain queued until that request's identity is known.
/// `RunningRequest.owner` is the sole sender of response events, delivers them
/// in contract order, and either delivers a terminal
/// `ResponseEnd`/`RequestFailed` before exiting or exits so its monitor reports
/// transport death.
pub type Transport {
  Transport(
    start_streaming: fn(HttpRequest, Subject(HttpEvent)) ->
      Result(RunningRequest, String),
  )
}

/// The production transport: Erlang `httpc` in asynchronous streaming
/// mode, wrapped so chunks arrive as `HttpEvent` messages on the subject.
/// The FFI shim owns a process that retains the exact OTP request id, monitors
/// the provider request owner, and calls `httpc:cancel_request/1` for explicit
/// cancellation or owner death.
///
/// ## Examples
///
/// ```gleam
/// let transport = http.httpc_transport()
/// // stream.run(transport, request, machine, ...)
/// ```
///
pub fn httpc_transport() -> Transport {
  Transport(start_streaming: fn(request, subject) {
    ffi_httpc.start_stream_request(
      request.method,
      request.url,
      request.headers,
      request.body,
      fn(status, headers) {
        process.send(subject, ResponseStatus(status:, headers:))
      },
      fn(chunk) { process.send(subject, ResponseChunk(chunk:)) },
      fn() { process.send(subject, ResponseEnd) },
      fn(reason) { process.send(subject, RequestFailed(reason:)) },
    )
    |> result.map(fn(owner) {
      RunningRequest(owner:, cancel: fn() {
        ffi_httpc.cancel_stream_request(owner)
      })
    })
  })
}
