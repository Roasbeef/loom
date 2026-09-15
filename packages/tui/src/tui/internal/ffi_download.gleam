//// Gun's streaming protocol has no typed Gleam binding. These adapters only
//// translate its native calls and messages; download policy stays in Gleam.
//// Neither stdlib, gleam_erlang, gleam_otp nor weft exposes TLS HTTP streams.

import gleam/erlang/process.{type Pid}

/// The native identifier of one HTTP request.
pub type Stream

/// Whether an HTTP message completes the response.
pub type Completion {
  /// More response messages follow.
  More

  /// This is the final response message.
  Finished
}

/// A bounded HTTP/1 response event.
pub type Event {
  /// Response metadata precedes any body bytes.
  Headers(
    /// Whether this response has no body to receive.
    completion: Completion,
    /// The HTTP response status.
    status: Int,
    /// Lowercase header names and their unchanged values.
    headers: List(#(String, String)),
  )

  /// One flow-controlled body fragment.
  Data(
    /// Whether this fragment completes the body.
    completion: Completion,
    /// One flow-controlled body fragment.
    bytes: BitArray,
  )

  /// Informational responses carry no artifact data.
  Inform

  /// Trailers complete a chunked response.
  Trailers
}

/// Opens a TLS connection with system roots and hostname verification.
///
/// ## Examples
///
/// `open("github.com", 443)` starts a connection owned by the caller.
@external(erlang, "tui_download_ffi", "open")
pub fn open(host: String, port: Int) -> Result(Pid, String)

/// Starts a GET with one body-message credit after TLS is established.
///
/// ## Examples
///
/// `request(connection, "/asset")` returns the stream identifier.
@external(erlang, "tui_download_ffi", "request")
pub fn request(connection: Pid, path: String) -> Result(Stream, String)

/// Receives one response event, with a bounded idle wait.
///
/// ## Examples
///
/// `receive(connection, stream)` answers with headers or one body fragment.
@external(erlang, "tui_download_ffi", "next")
pub fn receive(connection: Pid, stream: Stream) -> Result(Event, String)

/// Grants one more body-message credit after the prior fragment is written.
///
/// ## Examples
///
/// `credit(connection, stream)` resumes the paused response.
@external(erlang, "tui_download_ffi", "credit")
pub fn credit(connection: Pid, stream: Stream) -> Nil

/// Stops the connection normally and waits for transport cleanup.
///
/// ## Examples
///
/// `close(connection)` also cancels an unread error response.
@external(erlang, "tui_download_ffi", "close")
pub fn close(connection: Pid) -> Nil
