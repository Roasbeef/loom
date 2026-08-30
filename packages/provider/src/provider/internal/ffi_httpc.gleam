//// FFI shim for streaming HTTP over Erlang `httpc`.
////
//// This is the one place the provider package touches a socket. The Gleam
//// ecosystem has no streaming HTTP client (`gleam_httpc` is synchronous
//// only), so the shim drives OTP's `httpc` in asynchronous streaming mode
//// and forwards each response event to an injected callback. Everything
//// above this raw chunk stream is pure Gleam.
////
//// There is intentionally no provider policy here. Selection, retries,
//// timeouts, terminal arbitration, and transitive ownership remain in Gleam.
//// These two externals expose only what OTP does not provide as typed Gleam
//// values: start a raw `httpc` message stream, then cancel that exact stream
//// while waiting for its handler and receiver to exit.

import gleam/erlang/process.{type Pid}

/// The opaque native handle for one asynchronous HTTP request.
///
/// Besides OTP's request id, the Erlang shim retains the dedicated handler and
/// raw receiver whose exits prove that cancellation closed the request socket
/// and stopped raw message delivery.
pub type RequestId

/// Starts one HTTP request and streams the response through the callbacks:
/// `on_status` once, then `on_chunk` per body fragment, then `on_end`
/// once — or `on_failure` once at any point. Returns the spawned event receiver
/// and opaque native request id; startup failure is returned directly.
///
/// Uses `httpc:request/4` with `{sync, false}` and `{stream, self}` so
/// body chunks arrive as messages in the owner process's mailbox, which
/// the Erlang shim (`provider_ffi:start_stream_request/8`) receives
/// selectively and forwards. No pure alternative exists: chunked response delivery is
/// only available through `httpc`'s message protocol (or a third-party
/// client), and selective receive on `{http, ...}` tuples cannot be
/// expressed in Gleam. The shim disables redirects and supported automatic
/// retries so the captured handler cannot migrate behind the stable request
/// id, and waits through a transient `httpc_manager` restart rather than
/// publishing an unknown drain witness. It also calls
/// `application:ensure_all_started/1` for `inets` and `ssl` so the client works
/// without a release boot script.
///
/// ## Examples
///
/// ```gleam
/// ffi_httpc.start_stream_request(
///   "POST",
///   "https://api.example.test/v1/responses",
///   headers,
///   body,
///   on_status,
///   on_chunk,
///   on_end,
///   on_failure,
/// )
/// // -> Ok(#(receiver, request_id))
/// ```
///
@external(erlang, "provider_ffi", "start_stream_request")
pub fn start_stream_request(
  method: String,
  url: String,
  headers: List(#(String, String)),
  body: String,
  on_status: fn(Int, List(#(String, String))) -> Nil,
  on_chunk: fn(BitArray) -> Nil,
  on_end: fn() -> Nil,
  on_failure: fn(String) -> Nil,
) -> Result(#(Pid, RequestId), String)

/// Cancels the exact OTP request identified by `request_id` and returns only
/// after its dedicated native handler and raw receiver have exited. OTP
/// cancellation itself is asynchronous and may race a response already in
/// flight, so the provider request owner remains the only process allowed to
/// choose a terminal event.
///
/// ## Examples
///
/// ```gleam
/// ffi_httpc.cancel_stream_request(request_id)
/// // Returns after the handler and raw receiver have exited.
/// ```
///
@external(erlang, "provider_ffi", "cancel_stream_request")
pub fn cancel_stream_request(request_id: RequestId) -> Nil
