//// Fixed OTP SSL operations for the remote TLS boundary.
//// Neither glisten nor stratus exposes mandatory client certificates together
//// with verified client connections and exact peer DER. OTP SSL supplies those
//// operations; this module admits no Dynamic values or caller options.

import gleam/erlang/process.{type Pid}

/// Parsed local credentials, held only at this foreign boundary.
pub type Material

/// Passive OTP SSL socket, including a listening socket.
pub type Socket

/// Fixed bind choices prevent resolving unbounded listener strings.
pub type Address {
  /// IPv4 loopback for local callers and fixtures.
  Loopback

  /// All IPv4 interfaces for an explicitly provisioned service.
  AnyIpv4
}

/// Bounded fault categories; OTP diagnostics and key material never escape.
pub type Fault {
  /// The finite operation budget expired.
  TimedOut

  /// Certificate validation or exact pin verification failed.
  PeerRejected

  /// The peer closed before the requested bytes arrived.
  SocketClosed

  /// A socket operation failed without a more specific safe category.
  IoFailed

  /// DER or the single unencrypted PEM private key is invalid.
  InvalidMaterial

  /// SSL application startup failed.
  Unavailable

  /// The caller could not transfer socket ownership.
  TransferFailed
}

/// Starts OTP SSL; the service should call this once during supervised boot.
///
/// ## Examples
/// ```gleam
/// ffi_tls.start() // -> Ok(Nil)
/// ```
@external(erlang, "executor_tls_ffi", "start")
pub fn start() -> Result(Nil, Fault)

/// Parses already size-checked certificates and a private key using public_key.
///
/// ## Examples
/// ```gleam
/// ffi_tls.prepare(<<>>, <<>>, <<>>) // -> Error(InvalidMaterial)
/// ```
@external(erlang, "executor_tls_ffi", "prepare")
pub fn prepare(
  ca: BitArray,
  cert: BitArray,
  key: BitArray,
) -> Result(Material, Fault)

/// Creates ssl:listen with fixed peer verification and passive raw options.
///
/// ## Examples
/// ```gleam
/// ffi_tls.listen(material, pin, ffi_tls.Loopback, 0, 1000)
/// ```
@external(erlang, "executor_tls_ffi", "listen")
pub fn listen(
  material: Material,
  pin: BitArray,
  address: Address,
  port: Int,
  send_ms: Int,
) -> Result(Socket, Fault)

/// Accepts and verifies under one cumulative accept/handshake deadline.
///
/// ## Examples
/// ```gleam
/// ffi_tls.accept(listener, pin, 1000)
/// ```
@external(erlang, "executor_tls_ffi", "accept")
pub fn accept(
  listener: Socket,
  pin: BitArray,
  milliseconds: Int,
) -> Result(Socket, Fault)

/// Connects passive TCP, then upgrades through ssl:connect/3 with hostname and
/// leaf-pin verification. Both stages spend one monotonic deadline. OTP shares
/// a TCP timer across address attempts and Erlang DNS, but native DNS uses its
/// resolver timeout instead. Elapsed resolution time still reduces TLS time.
///
/// ## Examples
/// ```gleam
/// ffi_tls.connect(material, pin, "localhost", 443, #(1000, 5000))
/// ```
@external(erlang, "executor_tls_ffi", "connect")
pub fn connect(
  material: Material,
  pin: BitArray,
  hostname: String,
  port: Int,
  deadlines: #(Int, Int),
) -> Result(Socket, Fault)

/// Receives a positive bounded exact byte count through ssl:recv/3.
///
/// ## Examples
/// ```gleam
/// ffi_tls.receive_exact(socket, 4, 1000)
/// ```
@external(erlang, "executor_tls_ffi", "receive_exact")
pub fn receive_exact(
  socket: Socket,
  bytes: Int,
  milliseconds: Int,
) -> Result(BitArray, Fault)

/// Sends bounded bytes; OTP's finite send timeout closes on any failure.
///
/// ## Examples
/// ```gleam
/// ffi_tls.send(socket, <<0, 0, 0, 1, 42>>)
/// ```
@external(erlang, "executor_tls_ffi", "send")
pub fn send(socket: Socket, bytes: BitArray) -> Result(Nil, Fault)

/// Uses ssl:controlling_process/2; only the current controller can hand off.
///
/// ## Examples
/// ```gleam
/// ffi_tls.transfer(socket, reader_pid)
/// ```
@external(erlang, "executor_tls_ffi", "transfer")
pub fn transfer(socket: Socket, owner: Pid) -> Result(Nil, Fault)

/// Closes with zero peer wait; repeated calls are harmless.
///
/// ## Examples
/// ```gleam
/// ffi_tls.close(socket) // -> Nil
/// ```
@external(erlang, "executor_tls_ffi", "close")
pub fn close(socket: Socket) -> Nil

/// Reads the assigned port using ssl:sockname/1.
///
/// ## Examples
/// ```gleam
/// ffi_tls.port(listener)
/// ```
@external(erlang, "executor_tls_ffi", "port")
pub fn port(socket: Socket) -> Result(Int, Fault)

/// Local monotonic milliseconds for cumulative socket budgets, not wire time.
///
/// ## Examples
/// ```gleam
/// ffi_tls.now() // -> A local monotonic millisecond value.
/// ```
@external(erlang, "executor_tls_ffi", "now")
pub fn now() -> Int
