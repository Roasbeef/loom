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
//// These three externals expose only what OTP does not provide as typed Gleam
//// values: allocate a parked raw-message owner, grant that owner permission to
//// start, then cancel it while waiting for its private handler to exit.

import gleam/erlang/process.{type Pid}

/// The native process which owns one asynchronous HTTP request.
///
/// This alias remains a `Pid` so Gleam custodians can monitor and publish it,
/// while the only valid messages remain confined to this FFI module.
pub type RequestOwner =
  Pid

/// Allocates a parked owner for one HTTP request.
///
/// Allocation starts no application and opens no socket. The caller publishes
/// this PID before granting `begin_stream_request`; that ordering is the reason
/// preparation cannot be folded into the begin external.
///
/// ## Examples
///
/// ```gleam
/// let owner = ffi_httpc.prepare_stream_request(
///   on_status,
///   on_chunk,
///   on_end,
///   on_failure,
/// )
/// // No network work has started yet.
/// ```
///
@external(erlang, "provider_ffi", "prepare_stream_request")
pub fn prepare_stream_request(
  on_status: fn(Int, List(#(String, String))) -> Nil,
  on_chunk: fn(BitArray) -> Nil,
  on_end: fn() -> Nil,
  on_failure: fn(String) -> Nil,
) -> RequestOwner

/// Grants a prepared owner permission to start its request.
///
/// The native owner captures the exact handler registered for the request
/// before forwarding callbacks. Handler lookup uses the independent handler
/// supervisor, so replacing `httpc_manager` cannot erase the socket witness.
/// `httpc` startup failure is reported through `on_failure`.
///
/// ## Examples
///
/// ```gleam
/// ffi_httpc.begin_stream_request(
///   owner,
///   "POST",
///   "https://api.example.test/v1/responses",
///   headers,
///   body,
/// )
/// ```
///
@external(erlang, "provider_ffi", "begin_stream_request")
pub fn begin_stream_request(
  owner: RequestOwner,
  method: String,
  url: String,
  headers: List(#(String, String)),
  body: String,
) -> Nil

/// Requests cancellation of the native owner.
///
/// Calls before begin and calls after normal completion are harmless. OTP
/// cancellation remains asynchronous internally; the owner's eventual `Down`
/// is the separate drain acknowledgement consumed by the Gleam custodian.
///
/// ## Examples
///
/// ```gleam
/// ffi_httpc.cancel_stream_request(owner)
/// // Monitor `owner` when the native request subtree must be drained.
/// ```
///
@external(erlang, "provider_ffi", "cancel_stream_request")
pub fn cancel_stream_request(owner: RequestOwner) -> Nil
