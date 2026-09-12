//// One blocking unix-domain-socket exchange with the Herdr client daemon.
////
//// Herdr's agent-state protocol is newline-delimited JSON over a unix socket
//// every integrated host agent already inherits the path to. Nothing in
//// `gleam_stdlib`, `gleam_erlang`, `gleam_otp` or weft can open a
//// unix-domain stream — `gleam_erlang` exposes no socket API at all — so
//// the connect/send/receive/close exchange is this module's one external,
//// held to the minimum: a single round trip with a deadline on each phase.
////
//// The caller is the reporter process in `tui/herdr`, never the terminal
//// loop: a connect to a stale socket path can outlive its usefulness by the
//// whole timeout, and only a dedicated process may pay that.

/// Performs one request/response exchange over a unix-domain socket.
///
/// Connects OTP `gen_tcp` to the address `{local, Path}`, which is the
/// only unix-domain transport OTP exposes. Sends `payload`, waits up to
/// `timeout_ms` for one reply, closes the socket, and answers the reply.
/// A failed connect, a timeout, or a close before any byte is the same
/// `Error` to the caller, because the report is best-effort and the only
/// answer the reporter acts on is that the daemon did not take it.
@external(erlang, "tui_ffi", "herdr_exchange")
pub fn exchange(
  path: String,
  payload: String,
  timeout_ms: Int,
) -> Result(String, String)
