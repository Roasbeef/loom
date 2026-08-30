//// The HTTP transport seam.
////
//// The gateway and adapters never talk to a socket directly: they hand a
//// `HttpRequest` to an injected `Transport`, which delivers the response
//// as a stream of `HttpEvent` messages to a subject. Tests inject a
//// transport that replays fixture events; production wires the Erlang
//// `httpc` streaming shim via `httpc_transport`. A minimal Gleam custodian
//// witnesses a worker, the raw receiver, and the native request beneath it;
//// parsing and response folds above the `HttpEvent` boundary retain the
//// sans-io shape from the style guide.
////
//// Secrets (API keys) appear only inside `HttpRequest.headers`, which
//// flows exclusively into the transport. No `HttpEvent`, error, or stream
//// event ever carries the request back out (spec §3.3 invariant 4).

import gleam/erlang/process.{type Pid, type Subject}
import provider/custodian
import provider/internal/ffi_httpc

type NativeControl {
  CancelNative
}

type NativeMessage {
  NativeStatus(status: Int, headers: List(#(String, String)))
  NativeChunk(chunk: BitArray)
  NativeEnd
  NativeFailure(reason: String)
}

type NativeEvent {
  Control(NativeControl)
  Http(NativeMessage)
  ParentDown(process.Down)
  ReceiverDown(process.Down)
}

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
    /// The process whose exit proves the native request and receiver stopped.
    owner: Pid,
    /// The idempotent capability which asks that owner to tear down the request.
    cancel: fn() -> Nil,
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
/// A small Gleam custodian exists before native startup and queues
/// cancellation. Its worker retains the opaque OTP request id and forwards
/// `HttpEvent`s; once the raw receiver exists, the worker publishes both that
/// pid and native cancel capability to the custodian. The public custodian can
/// therefore outlive a crashed worker and retires only after the receiver and
/// any cancellation helper are gone. The FFI is limited to starting `httpc`,
/// selecting its raw messages, and turning OTP's asynchronous cancellation
/// into handler-and-receiver exit acknowledgement. Lifecycle policy remains
/// here in typed Gleam.
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
    start_httpc(request, subject)
  })
}

fn start_httpc(
  request: HttpRequest,
  subject: Subject(HttpEvent),
) -> Result(RunningRequest, String) {
  let parent = process.self()
  let ready = process.new_subject()
  let worker =
    process.spawn_unlinked(fn() {
      let control = process.new_subject()
      let begin = process.new_subject()
      process.send(ready, #(control, begin))
      let owner = process.receive_forever(begin)
      let parent_monitor = process.monitor(parent)
      let native = process.new_subject()
      case
        ffi_httpc.start_stream_request(
          request.method,
          request.url,
          request.headers,
          request.body,
          fn(status, headers) {
            process.send(native, NativeStatus(status:, headers:))
          },
          fn(chunk) { process.send(native, NativeChunk(chunk:)) },
          fn() { process.send(native, NativeEnd) },
          fn(reason) { process.send(native, NativeFailure(reason:)) },
        )
      {
        Error(reason) -> {
          process.demonitor_process(parent_monitor)
          process.send(subject, RequestFailed(reason:))
        }
        Ok(#(receiver, request_id)) -> {
          let receiver_monitor = process.monitor(receiver)
          let adopted =
            custodian.adopt_owner(owner, receiver, fn() {
              ffi_httpc.cancel_stream_request(request_id)
            })
          case adopted {
            True ->
              own_native_request(
                request_id,
                receiver,
                subject,
                control,
                native,
                parent_monitor,
                receiver_monitor,
              )
            False ->
              finish_native(
                request_id,
                receiver,
                parent_monitor,
                receiver_monitor,
              )
          }
        }
      }
    })
  let #(control, begin) = process.receive_forever(ready)
  let owner = custodian.start(worker, control, CancelNative, parent)
  process.send(begin, owner)
  Ok(
    RunningRequest(owner: custodian.owner(owner), cancel: fn() {
      custodian.cancel(owner)
    }),
  )
}

fn own_native_request(
  request_id: ffi_httpc.RequestId,
  receiver: Pid,
  subject: Subject(HttpEvent),
  control: Subject(NativeControl),
  native: Subject(NativeMessage),
  parent_monitor: process.Monitor,
  receiver_monitor: process.Monitor,
) -> Nil {
  let event =
    process.new_selector()
    |> process.select_map(control, Control)
    |> process.select_map(native, Http)
    |> process.select_specific_monitor(parent_monitor, ParentDown)
    |> process.select_specific_monitor(receiver_monitor, ReceiverDown)
    |> process.selector_receive_forever()
  case event {
    Control(CancelNative) | ParentDown(_down) ->
      stop_native(request_id, receiver, parent_monitor, receiver_monitor)
    ReceiverDown(_down) -> {
      ffi_httpc.cancel_stream_request(request_id)
      process.demonitor_process(parent_monitor)
      process.send(
        subject,
        RequestFailed(reason: "http event receiver stopped unexpectedly"),
      )
    }
    Http(NativeStatus(status:, headers:)) -> {
      process.send(subject, ResponseStatus(status:, headers:))
      own_native_request(
        request_id,
        receiver,
        subject,
        control,
        native,
        parent_monitor,
        receiver_monitor,
      )
    }
    Http(NativeChunk(chunk:)) -> {
      process.send(subject, ResponseChunk(chunk:))
      own_native_request(
        request_id,
        receiver,
        subject,
        control,
        native,
        parent_monitor,
        receiver_monitor,
      )
    }
    Http(NativeEnd) -> {
      process.send(subject, ResponseEnd)
      finish_native(request_id, receiver, parent_monitor, receiver_monitor)
    }
    Http(NativeFailure(reason:)) -> {
      process.send(subject, RequestFailed(reason:))
      finish_native(request_id, receiver, parent_monitor, receiver_monitor)
    }
  }
}

fn stop_native(
  request_id: ffi_httpc.RequestId,
  receiver: Pid,
  parent_monitor: process.Monitor,
  receiver_monitor: process.Monitor,
) -> Nil {
  finish_native(request_id, receiver, parent_monitor, receiver_monitor)
}

fn finish_native(
  request_id: ffi_httpc.RequestId,
  receiver: Pid,
  parent_monitor: process.Monitor,
  receiver_monitor: process.Monitor,
) -> Nil {
  // OTP cancellation is asynchronous, but the FFI does not return until the
  // dedicated native handler has exited and closed its socket.
  ffi_httpc.cancel_stream_request(request_id)
  process.kill(receiver)
  case process.is_alive(receiver) {
    False -> Nil
    True -> {
      let _down =
        process.new_selector()
        |> process.select_specific_monitor(receiver_monitor, fn(_down) { Nil })
        |> process.selector_receive_forever()
      Nil
    }
  }
  process.demonitor_process(parent_monitor)
  process.demonitor_process(receiver_monitor)
}
