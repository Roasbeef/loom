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

import gleam/erlang/process.{type Subject}
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

/// A streaming HTTP transport as a record of functions, so tests can
/// inject fixtures and production can inject `httpc_transport`.
///
/// Constructor invariants: `send_streaming` delivers the response for the
/// given request to the subject as `HttpEvent` messages obeying the
/// ordering contract on `HttpEvent`, and eventually always delivers a
/// terminal `ResponseEnd` or `RequestFailed`. It may be called from any
/// process and may block until the response completes.
pub type Transport {
  Transport(send_streaming: fn(HttpRequest, Subject(HttpEvent)) -> Nil)
}

/// The production transport: Erlang `httpc` in asynchronous streaming
/// mode, wrapped so chunks arrive as `HttpEvent` messages on the subject.
/// The FFI shim (`provider/internal/ffi_httpc`) blocks the calling
/// process while it pumps the socket, so callers run it on a dedicated
/// process — `provider/stream.run` does exactly that.
///
/// ## Examples
///
/// ```gleam
/// let transport = http.httpc_transport()
/// // stream.run(transport, request, machine, ...)
/// ```
///
pub fn httpc_transport() -> Transport {
  Transport(send_streaming: fn(request, subject) {
    ffi_httpc.stream_request(
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
  })
}
