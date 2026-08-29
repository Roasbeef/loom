//// FFI shim for streaming HTTP over Erlang `httpc`.
////
//// This is the one place the provider package touches a socket. The Gleam
//// ecosystem has no streaming HTTP client (`gleam_httpc` is synchronous
//// only), so the shim drives OTP's `httpc` in asynchronous streaming mode
//// and forwards each response event to an injected callback. Everything
//// above this raw chunk stream is pure Gleam.

import gleam/erlang/process.{type Pid}

/// Starts one HTTP request and streams the response through the callbacks:
/// `on_status` once, then `on_chunk` per body fragment, then `on_end`
/// once — or `on_failure` once at any point. Returns the spawned request
/// owner immediately; startup failure is delivered through `on_failure`.
/// The owner retains the exact OTP request id and monitors the calling
/// process. Cancellation queued during startup is therefore handled as soon
/// as `httpc:request/4` returns the id.
///
/// Uses `httpc:request/4` with `{sync, false}` and `{stream, self}` so
/// body chunks arrive as messages in the owner process's mailbox, which
/// the Erlang shim (`provider_ffi:start_stream_request/8`) receives
/// selectively and forwards. No pure alternative exists: chunked response delivery is
/// only available through `httpc`'s message protocol (or a third-party
/// client), and selective receive on `{http, ...}` tuples cannot be
/// expressed in Gleam. The shim also calls `application:ensure_all_started/1`
/// for `inets` and `ssl` so the client works without a release boot script.
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
) -> Result(Pid, String)

/// Cancels the exact OTP request retained by `owner`. OTP cancellation is
/// asynchronous and may race a response already in flight, so the provider
/// request owner remains the only process allowed to choose a terminal event.
@external(erlang, "provider_ffi", "cancel_stream_request")
pub fn cancel_stream_request(owner: Pid) -> Nil
