//// A mutually authenticated TLS stream of length-prefixed frames, the
//// transport between an orchestrator and an untrusted executor
//// (protocol-change/109).
////
//// No pure alternative exists: gleam_stdlib, gleam_erlang, gleam_otp and weft
//// open no TLS socket, and mist, the one server in the tree, cannot require a
//// client certificate with a pinned digest. So the `ssl` calls are foreign, in
//// `client_tls_stream_ffi.erl`, and this module is their only door. It takes
//// no option list and no callback: the options are fixed there, and the
//// caller chooses only the credentials, the pins, the frame limit and the
//// deadlines. Only `client/remote/untrusted_link`,
//// `client/remote/untrusted_gateway` and `client/untrusted_config` (for the
//// `Credentials` record) import it.
////
//// A stream belongs to one process at a time. Frames arrive at that process
//// as messages, one per `arm`, and `select` maps them into its selector.
////
//// ## Flow
////
//// `listen` → `accept` → `handshake` → `connect` → `arm` → `select` → `send` →
//// `close`

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process.{type Pid, type Selector}

/// A listening socket.
pub type Listener

/// One TLS connection, after its handshake.
pub type Stream

/// The files a node presents and verifies with, as PEM paths.
pub type Credentials {
  Credentials(
    /// The authority every peer's certificate must chain to.
    ca: String,
    /// This node's certificate.
    certificate: String,
    /// This node's private key.
    key: String,
  )
}

/// Why a stream operation failed. The vocabulary carries no OTP diagnostic,
/// which could hold a path or a peer's text.
pub type Failure {
  /// A credential file could not be read, or an address could not be parsed.
  InvalidConfiguration

  /// The peer's certificate did not chain to the authority or did not hash
  /// to a pin, or the handshake failed for another TLS reason.
  Refused

  /// Nothing happened within the deadline.
  TimedOut

  /// The connection or the listener is closed.
  Closed

  /// The operating system refused, or the peer could not be reached.
  Unavailable
}

/// What a stream delivered to the process that owns it.
pub type Inbound {
  /// One frame's body, without its length prefix.
  Received(frame: BitArray)

  /// The peer closed the connection.
  Ended

  /// The connection failed.
  Broken
}

/// Listens at `address` (an IP literal, or `""` for every interface) and
/// `port` (zero picks one), admitting peers whose leaf hashes to one of
/// `pins`. `max_frame` bounds every frame the streams it accepts will read.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(listener) =
/// //   ffi_tls_stream.listen("127.0.0.1", 0, credentials, [pin], 1_048_576)
/// ```
pub fn listen(
  address: String,
  port: Int,
  credentials: Credentials,
  pins: List(BitArray),
  max_frame: Int,
) -> Result(Listener, Failure) {
  raw_listen(
    address,
    port,
    credentials.ca,
    credentials.certificate,
    credentials.key,
    pins,
    max_frame,
  )
}

/// The foreign `listen`, with the credentials spread into their three paths.
@external(erlang, "client_tls_stream_ffi", "listen")
fn raw_listen(
  address: String,
  port: Int,
  ca: String,
  certificate: String,
  key: String,
  pins: List(BitArray),
  max_frame: Int,
) -> Result(Listener, Failure)

/// Waits up to `within_ms` for one connection, returned before its TLS
/// handshake so the caller never waits on a slow client. Hand it to the
/// process that will own it, which runs `handshake`.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(raw) = ffi_tls_stream.accept(listener, 60_000)
/// ```
@external(erlang, "client_tls_stream_ffi", "accept")
pub fn accept(listener: Listener, within_ms: Int) -> Result(Stream, Failure)

/// Runs the server side of an accepted connection's handshake within
/// `within_ms`. Only the stream's owner may call this; a failed handshake
/// closes the connection.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(stream) = ffi_tls_stream.handshake(raw, 10_000)
/// ```
@external(erlang, "client_tls_stream_ffi", "handshake")
pub fn handshake(stream: Stream, within_ms: Int) -> Result(Stream, Failure)

/// Dials `host` at `port` and runs the handshake within `within_ms`,
/// admitting the peer only if its leaf hashes to `pin`. The caller owns the
/// stream it returns.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(stream) =
/// //   ffi_tls_stream.connect("10.0.0.7", 7443, credentials, pin, 1_048_576, 5000)
/// ```
pub fn connect(
  host: String,
  port: Int,
  credentials: Credentials,
  pin: BitArray,
  max_frame: Int,
  within_ms: Int,
) -> Result(Stream, Failure) {
  raw_connect(
    host,
    port,
    credentials.ca,
    credentials.certificate,
    credentials.key,
    pin,
    max_frame,
    within_ms,
  )
}

/// The foreign `connect`, with the credentials spread into their three paths.
@external(erlang, "client_tls_stream_ffi", "connect")
fn raw_connect(
  host: String,
  port: Int,
  ca: String,
  certificate: String,
  key: String,
  pin: BitArray,
  max_frame: Int,
  within_ms: Int,
) -> Result(Stream, Failure)

/// Sends one frame.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(Nil) = ffi_tls_stream.send(stream, <<"{}":utf8>>)
/// ```
@external(erlang, "client_tls_stream_ffi", "send")
pub fn send(stream: Stream, frame: BitArray) -> Result(Nil, Failure)

/// Asks for the next frame, which arrives at the owning process as one
/// message that `select` maps.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(Nil) = ffi_tls_stream.arm(stream)
/// ```
@external(erlang, "client_tls_stream_ffi", "arm")
pub fn arm(stream: Stream) -> Result(Nil, Failure)

/// Gives the stream to `pid`. Only its current owner may call this.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(Nil) = ffi_tls_stream.hand_to(stream, connection_pid)
/// ```
@external(erlang, "client_tls_stream_ffi", "hand_to")
pub fn hand_to(stream: Stream, pid: Pid) -> Result(Nil, Failure)

/// Closes the stream. Closing a closed stream does nothing.
///
/// ## Examples
///
/// ```gleam
/// // ffi_tls_stream.close(stream)
/// ```
@external(erlang, "client_tls_stream_ffi", "close")
pub fn close(stream: Stream) -> Nil

/// Closes the listener.
///
/// ## Examples
///
/// ```gleam
/// // ffi_tls_stream.close_listener(listener)
/// ```
@external(erlang, "client_tls_stream_ffi", "close_listener")
pub fn close_listener(listener: Listener) -> Nil

/// The SHA-256 of the peer's leaf, which is the pin the handshake admitted.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(pin) = ffi_tls_stream.peer_pin(stream)
/// ```
@external(erlang, "client_tls_stream_ffi", "peer_pin")
pub fn peer_pin(stream: Stream) -> Result(BitArray, Failure)

/// The port a listener is bound to.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(port) = ffi_tls_stream.port_of(listener)
/// ```
@external(erlang, "client_tls_stream_ffi", "port_of")
pub fn port_of(listener: Listener) -> Result(Int, Failure)

/// Adds the three messages a stream sends its owner to `selector`. The owner
/// holds one stream, so the messages are not told apart by socket.
///
/// ## Examples
///
/// ```gleam
/// // process.new_selector() |> ffi_tls_stream.select(Frame)
/// ```
pub fn select(
  selector: Selector(message),
  mapping: fn(Inbound) -> message,
) -> Selector(message) {
  selector
  |> process.select_record(atom.create("ssl"), 2, fn(record) {
    mapping(frame_of(record))
  })
  |> process.select_record(atom.create("ssl_closed"), 1, fn(_record) {
    mapping(Ended)
  })
  |> process.select_record(atom.create("ssl_error"), 2, fn(_record) {
    mapping(Broken)
  })
}

// The socket delivers a frame as a binary because the stream is opened in
// binary mode, so a record whose payload is anything else is a broken stream
// rather than a frame.
fn frame_of(record: Dynamic) -> Inbound {
  case decode.run(record, decode.at([2], decode.bit_array)) {
    Ok(frame) -> Received(frame)
    Error(_wrong) -> Broken
  }
}
