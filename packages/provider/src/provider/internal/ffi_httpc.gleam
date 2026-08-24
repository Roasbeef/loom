//// FFI shim for streaming HTTP over Erlang `httpc`.
////
//// This is the one place the provider package touches a socket. The Gleam
//// ecosystem has no streaming HTTP client (`gleam_httpc` is synchronous
//// only), so the shim drives OTP's `httpc` in asynchronous streaming mode
//// and forwards each response event to an injected callback. Everything
//// above this raw chunk stream is pure Gleam.

/// Sends one HTTP request and streams the response through the callbacks:
/// `on_status` once, then `on_chunk` per body fragment, then `on_end`
/// once — or `on_failure` once at any point. Blocks the calling process
/// until the response is complete or failed.
///
/// Uses `httpc:request/4` with `{sync, false}` and `{stream, self}` so
/// body chunks arrive as messages in the calling process's mailbox, which
/// the Erlang shim (`provider_ffi:stream_request/8`) receives selectively
/// and forwards. No pure alternative exists: chunked response delivery is
/// only available through `httpc`'s message protocol (or a third-party
/// client), and selective receive on `{http, ...}` tuples cannot be
/// expressed in Gleam. The shim also calls `application:ensure_all_started/1`
/// for `inets` and `ssl` so the client works without a release boot script.
@external(erlang, "provider_ffi", "stream_request")
pub fn stream_request(
  method: String,
  url: String,
  headers: List(#(String, String)),
  body: String,
  on_status: fn(Int, List(#(String, String))) -> Nil,
  on_chunk: fn(BitArray) -> Nil,
  on_end: fn() -> Nil,
  on_failure: fn(String) -> Nil,
) -> Nil
