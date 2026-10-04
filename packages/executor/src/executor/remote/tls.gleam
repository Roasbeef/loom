//// A small mutually authenticated, passive binary TLS transport.
////
//// A connection exists only after trusted-CA validation, expiry checks and an
//// exact SHA-256 leaf pin. Clients also verify the configured hostname. Neither
//// a claimed hello nor any application bytes establish identity here. TLS 1.2
//// and 1.3 are the only versions. Session reuse is disabled so authentication
//// runs on every connection.
////
//// Settings retain one DER trust anchor, one DER leaf and one unencrypted PEM
//// private key, each at most 16 KiB. The trust anchor signs the leaf directly
//// or the peer supplies its intermediate chain (at most three intermediates).
//// Frame bodies are nonempty byte arrays of at most 256 KiB. A single monotonic
//// budget covers the four-byte prefix and the complete body, including fragments.
//// A framing or read failure closes the stream because resynchronization is
//// unsafe. The payload remains opaque to this primitive's caller.
////
//// No actor, reader, writer, reconnect or queue is created here. The caller owns
//// supervised bounded reading/writing and aggregate connection capacity. The
//// creating process controls each socket; transfer explicitly hands custody to
//// a live supervised owner before that owner starts reading. Serialize writes
//// and allow exactly one read at a time. Passive mode publishes no data messages
//// into the application's mailbox. OTP and kernel buffers still need aggregate
//// budgeting by the service. `start` belongs in service boot, before settings.

import executor/internal/ffi_tls
import gleam/bit_array
import gleam/erlang/process.{type Pid}
import gleam/list
import gleam/result
import gleam/string

/// Fixed maximum body size; the prefix is checked before asking OTP for a body.
pub const max_frame_bytes = 262_144

/// Validated credentials, exact peer pin and finite operation budgets.
pub opaque type Settings {
  Settings(
    /// Parsed local credential bytes; no filesystem path or options bag.
    material: ffi_tls.Material,
    /// Exact expected peer leaf SHA-256, independent of claimed identity.
    pin: BitArray,
    /// Cumulative TCP/TLS or accept/handshake budget, 1..5000 milliseconds.
    /// Outbound native DNS retains OTP's separate resolver timeout.
    handshake_ms: Int,
    /// Complete prefix/body budget, 1..5000 milliseconds.
    frame_ms: Int,
    /// Fixed per-send timeout, 1..1000 milliseconds.
    send_ms: Int,
  )
}

/// Listening socket; accepting it authenticates the configured peer independently.
pub opaque type Listener {
  Listener(
    /// OTP socket controlled by the process which called listen.
    socket: ffi_tls.Socket,
    /// Validated authentication and timeout settings for each accepted peer.
    settings: Settings,
  )
}

/// An authenticated stream with no application identity claim attached.
pub opaque type Connection {
  Connection(
    /// Passive socket; the caller owns serialized reads and writes.
    socket: ffi_tls.Socket,
    /// SHA-256 of the authenticated peer DER leaf, already checked by OTP.
    pin: BitArray,
    /// Cumulative frame timeout used for every individual frame.
    frame_ms: Int,
  )
}

/// Deliberately small bind vocabulary; listener capacity belongs to its supervisor.
pub type Bind {
  /// Local IPv4 only.
  Loopback

  /// All IPv4 interfaces; provisioning chooses when to expose this listener.
  AnyIpv4
}

/// Bounded explicit failures, never raw certificate, key or OTP diagnostics.
pub type Error {
  /// Credential or pin size is invalid, or material could not be parsed.
  InvalidSettings

  /// An endpoint name or port is outside the admitted range.
  InvalidEndpoint

  /// A configured duration is zero, negative or above its fixed ceiling.
  InvalidDeadline

  /// An operation exceeded its finite deadline.
  Timeout

  /// PKIX, hostname or leaf-pin validation failed.
  AuthenticationFailed

  /// The stream ended, including a truncated header or body.
  Closed

  /// Socket I/O failed without a more specific safe category.
  TransportFailed

  /// SSL could not start.
  Unavailable

  /// The caller could not transfer controlling ownership.
  OwnershipFailed

  /// A frame is empty, non-byte-aligned or has an invalid prefix.
  InvalidFrame

  /// A declared or outgoing body exceeds the fixed maximum.
  FrameTooLarge
}

/// Starts OTP SSL once at the service's supervised boot boundary.
///
/// ## Examples
/// ```gleam
/// tls.start() // -> Ok(Nil)
/// ```
pub fn start() -> Result(Nil, Error) {
  ffi_tls.start() |> result.map_error(fault)
}

/// Validates sizes before any certificate/key decoding or option construction.
/// Inputs are one DER CA, one DER local leaf and one unencrypted PEM key.
///
/// ## Examples
/// ```gleam
/// assert tls.settings(<<>>, <<>>, <<>>, <<>>, 5000, 5000, 1000)
///   == Error(tls.InvalidSettings)
/// ```
pub fn settings(
  ca: BitArray,
  certificate: BitArray,
  private_key: BitArray,
  peer_pin: BitArray,
  handshake_ms: Int,
  frame_ms: Int,
  send_ms: Int,
) -> Result(Settings, Error) {
  use Nil <- result.try(material_sizes(ca, certificate, private_key, peer_pin))
  use Nil <- result.try(duration(handshake_ms, 5000))
  use Nil <- result.try(duration(frame_ms, 5000))
  use Nil <- result.try(duration(send_ms, 1000))
  use material <- result.try(
    ffi_tls.prepare(ca, certificate, private_key) |> result.map_error(fault),
  )
  Ok(Settings(material, peer_pin, handshake_ms, frame_ms, send_ms))
}

/// Creates a fixed-backlog (eight) listener; port zero requests an ephemeral port.
/// SSL must already be started; this function creates no accepting process.
///
/// ## Examples
/// ```gleam
/// tls.listen(settings, tls.Loopback, 0) // -> Ok(listener)
/// ```
pub fn listen(
  settings: Settings,
  bind: Bind,
  port: Int,
) -> Result(Listener, Error) {
  use Nil <- result.try(port_range(port, 0))
  let address = case bind {
    Loopback -> ffi_tls.Loopback
    AnyIpv4 -> ffi_tls.AnyIpv4
  }
  use socket <- result.map(
    ffi_tls.listen(
      settings.material,
      settings.pin,
      address,
      port,
      settings.send_ms,
    )
    |> result.map_error(fault),
  )
  Listener(socket, settings)
}

/// Returns the actual listener port, useful when provisioning port zero.
///
/// ## Examples
/// ```gleam
/// tls.port(listener) // -> Ok(port)
/// ```
pub fn port(listener: Listener) -> Result(Int, Error) {
  ffi_tls.port(listener.socket) |> result.map_error(fault)
}

/// Accepts one peer under a cumulative accept/handshake budget. A failed handshake
/// closes that peer socket and leaves the listener available to its owner.
///
/// ## Examples
/// ```gleam
/// tls.accept(listener) // -> Ok(connection) or a bounded error.
/// ```
pub fn accept(listener: Listener) -> Result(Connection, Error) {
  let settings = listener.settings
  use socket <- result.map(
    ffi_tls.accept(listener.socket, settings.pin, settings.handshake_ms)
    |> result.map_error(fault),
  )
  Connection(socket, settings.pin, settings.frame_ms)
}

/// Connects to a bounded ASCII hostname and verifies both that name and the pin.
/// Hostnames use 1..253 bytes containing letters, digits, dot or hyphen; IP text
/// is admitted but still subject to certificate hostname validation.
/// TCP establishment and TLS upgrade spend one monotonic handshake budget.
/// OTP shares the TCP timer across address attempts and Erlang DNS. Its native
/// resolver uses a separate resolver timeout and can exceed this budget. All
/// elapsed resolution time is subtracted before TLS; expiry closes raw TCP.
/// This is an OTP timeout contract, not a hard real-time scheduler guarantee.
///
/// ## Examples
/// ```gleam
/// tls.connect(settings, "localhost", 443) // -> Ok(connection)
/// ```
pub fn connect(
  settings: Settings,
  hostname: String,
  port: Int,
) -> Result(Connection, Error) {
  use Nil <- result.try(hostname_range(hostname))
  use Nil <- result.try(port_range(port, 1))
  use socket <- result.map(
    ffi_tls.connect(settings.material, settings.pin, hostname, port, #(
      settings.send_ms,
      settings.handshake_ms,
    ))
    |> result.map_error(fault),
  )
  Connection(socket, settings.pin, settings.frame_ms)
}

/// Returns the authenticated leaf pin; upper layers bind it to provisioned names.
///
/// ## Examples
/// ```gleam
/// tls.peer_pin(connection) // -> Exactly 32 authenticated bytes.
/// ```
pub fn peer_pin(connection: Connection) -> BitArray {
  connection.pin
}

/// Transfers controlling ownership; the old owner must stop using the socket
/// once this returns Ok. Reads remain passive, so no data mailbox is transferred.
///
/// ## Examples
/// ```gleam
/// tls.transfer(connection, reader_pid) // -> Ok(Nil)
/// ```
pub fn transfer(connection: Connection, owner: Pid) -> Result(Nil, Error) {
  ffi_tls.transfer(connection.socket, owner) |> result.map_error(fault)
}

/// Reads exactly one frame; the same deadline covers all prefix/body fragments.
/// Oversize and malformed prefixes are refused before any body receive/allocation.
/// Any read/framing error closes the socket, including partially read timeouts.
///
/// ## Examples
/// ```gleam
/// tls.receive(connection) // -> Ok(binary_body)
/// ```
pub fn receive(connection: Connection) -> Result(BitArray, Error) {
  let deadline = ffi_tls.now() + connection.frame_ms
  let received = {
    use header <- result.try(read_before(connection.socket, 4, deadline))
    use size <- result.try(frame_size(header))
    read_before(connection.socket, size, deadline)
  }
  close_on_error(connection, received)
}

/// Checks a body before constructing its prefix or calling SSL. The socket's
/// fixed send timeout is finite and every send failure closes the stream.
/// Invalid caller frames send no bytes and leave the connection usable.
///
/// ## Examples
/// ```gleam
/// tls.send(connection, <<0, 255, 1>>) // -> Ok(Nil)
/// ```
pub fn send(connection: Connection, body: BitArray) -> Result(Nil, Error) {
  use Nil <- result.try(body_size(body))
  let size = bit_array.byte_size(body)
  ffi_tls.send(connection.socket, <<size:size(32), body:bits>>)
  |> result.map_error(fault)
}

/// Idempotently closes a connection with no wait for a peer close_notify.
///
/// ## Examples
/// ```gleam
/// tls.close(connection) // -> Nil, including a repeated call.
/// ```
pub fn close(connection: Connection) -> Nil {
  ffi_tls.close(connection.socket)
}

/// Idempotently closes the listener; it does not close already accepted peers.
///
/// ## Examples
/// ```gleam
/// tls.close_listener(listener) // -> Nil
/// ```
pub fn close_listener(listener: Listener) -> Nil {
  ffi_tls.close(listener.socket)
}

fn material_sizes(
  ca: BitArray,
  cert: BitArray,
  key: BitArray,
  pin: BitArray,
) -> Result(Nil, Error) {
  case
    bounded_material(ca)
    && bounded_material(cert)
    && bounded_material(key)
    && bit_array.bit_size(pin) == 256
  {
    True -> Ok(Nil)
    False -> Error(InvalidSettings)
  }
}

fn bounded_material(bytes: BitArray) -> Bool {
  let size = bit_array.bit_size(bytes)
  size > 0 && size <= 16_384 * 8 && size % 8 == 0
}

fn duration(milliseconds: Int, maximum: Int) -> Result(Nil, Error) {
  case milliseconds >= 1 && milliseconds <= maximum {
    True -> Ok(Nil)
    False -> Error(InvalidDeadline)
  }
}

fn port_range(port: Int, minimum: Int) -> Result(Nil, Error) {
  case port >= minimum && port <= 65_535 {
    True -> Ok(Nil)
    False -> Error(InvalidEndpoint)
  }
}

fn hostname_range(hostname: String) -> Result(Nil, Error) {
  // Byte size is checked before to_utf_codepoints can allocate a list.
  case string.byte_size(hostname) >= 1 && string.byte_size(hostname) <= 253 {
    True ->
      case
        list.all(string.to_utf_codepoints(hostname), fn(character) {
          let code = string.utf_codepoint_to_int(character)
          code >= 65
          && code <= 90
          || code >= 97
          && code <= 122
          || code >= 48
          && code <= 57
          || code == 45
          || code == 46
        })
      {
        True -> Ok(Nil)
        False -> Error(InvalidEndpoint)
      }
    False -> Error(InvalidEndpoint)
  }
}

fn read_before(
  socket: ffi_tls.Socket,
  size: Int,
  deadline: Int,
) -> Result(BitArray, Error) {
  let remaining = deadline - ffi_tls.now()
  case remaining > 0 {
    True ->
      ffi_tls.receive_exact(socket, size, remaining) |> result.map_error(fault)
    False -> Error(Timeout)
  }
}

fn frame_size(header: BitArray) -> Result(Int, Error) {
  case header {
    <<0:size(32)>> -> Error(InvalidFrame)
    <<size:size(32)>> if size <= max_frame_bytes -> Ok(size)
    <<_:size(32)>> -> Error(FrameTooLarge)
    _ -> Error(InvalidFrame)
  }
}

fn body_size(body: BitArray) -> Result(Nil, Error) {
  let bits = bit_array.bit_size(body)
  case bits {
    0 -> Error(InvalidFrame)
    bits if bits % 8 != 0 -> Error(InvalidFrame)
    bits if bits > max_frame_bytes * 8 -> Error(FrameTooLarge)
    _ -> Ok(Nil)
  }
}

fn close_on_error(
  connection: Connection,
  received: Result(a, Error),
) -> Result(a, Error) {
  case received {
    Ok(_) -> received
    Error(_) -> {
      close(connection)
      received
    }
  }
}

fn fault(error: ffi_tls.Fault) -> Error {
  case error {
    ffi_tls.TimedOut -> Timeout
    ffi_tls.PeerRejected -> AuthenticationFailed
    ffi_tls.SocketClosed -> Closed
    ffi_tls.IoFailed -> TransportFailed
    ffi_tls.InvalidMaterial -> InvalidSettings
    ffi_tls.Unavailable -> Unavailable
    ffi_tls.TransferFailed -> OwnershipFailed
  }
}
