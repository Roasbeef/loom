//// The cap channel's AF_UNIX primitives — the broker end of the socket a
//// jailed satellite connects back on.
////
//// FFI confinement (spec §0.2): every `@external` the code-mode launcher
//// needs lives here, backed by `codemode_ffi.erl`. `codemode/launch`
//// consumes these from two small processes (a reader that owns the
//// accepted socket, a writer that frames outbound bytes), so the launch
//// logic above them stays ordinary Gleam and the host itself never sees a
//// socket at all.
////
//// The satellite side (`cap/internal/ffi_transport`) connects with
//// `gen_tcp:connect({local, Path}, 0, [binary, {active,false},
//// {packet,raw}])`, so this end listens with the matching options: a
//// `{local, Path}` address, binary frames, passive mode, raw packets.
//// Passive mode is load-bearing — Gleam owns frame boundaries (the host's
//// own length-prefix deframer), never the port driver.

/// A listening AF_UNIX stream socket. External type, never `Dynamic`: it
/// names the Erlang `gen_tcp` listen socket without exposing its shape.
///
/// Invariant: the socket file at the listened path exists until the
/// listener is closed *and* the path is unlinked — closing alone leaves
/// the inode behind, as AF_UNIX always does.
pub type Listener

/// An accepted AF_UNIX stream connection to one satellite.
///
/// Invariant: `recv` may only be called by the process that accepted it
/// (the controlling process); `send` and `close` are callable from any
/// process, which is what lets the writer and the reader share it.
pub type Socket

/// Why an accept did not produce a connection.
pub type AcceptError {
  /// No satellite connected within the timeout. Retryable: the caller
  /// polls so it can notice a node that died before ever connecting.
  AcceptTimeout

  /// The listener faulted or was closed under the accept.
  AcceptFailed(reason: String)
}

/// Creates and listens on an AF_UNIX stream socket at `path`.
///
/// Uses `gen_tcp:listen/2` with an `{ifaddr, {local, Path}}` address —
/// the only way to obtain an AF_UNIX listener on the BEAM, and not
/// AF_INET, so the jail's network-off policy still admits it. A stale
/// socket file at `path` is unlinked first; a path already in use by a
/// live listener fails in-band.
@external(erlang, "codemode_ffi", "listen_unix")
pub fn listen(path: String) -> Result(Listener, String)

/// Waits up to `timeout_ms` for a satellite to connect.
///
/// Uses `gen_tcp:accept/2`. The timeout is surfaced as its own variant
/// rather than an error string so the caller can poll and interleave
/// other work — noticing, for instance, that the node it launched died
/// before it ever reached the socket.
@external(erlang, "codemode_ffi", "accept_unix")
pub fn accept(
  listener: Listener,
  timeout_ms: Int,
) -> Result(Socket, AcceptError)

/// Blocks until some bytes arrive, returning whatever is available.
/// `Error` carries the reason the stream ended — a closed peer is the
/// ordinary end of an execution, not a fault.
///
/// Uses `gen_tcp:recv/2` with length 0 on a passive socket.
@external(erlang, "codemode_ffi", "socket_recv")
pub fn recv(socket: Socket) -> Result(BitArray, String)

/// Writes all of `bytes` to the socket.
///
/// Uses `gen_tcp:send/2`; a closed or faulted socket settles in-band so
/// the writer never crashes the launch.
@external(erlang, "codemode_ffi", "socket_send")
pub fn send(socket: Socket, bytes: BitArray) -> Result(Nil, String)

/// Closes an accepted connection. Idempotent from the caller's view.
///
/// Uses `gen_tcp:close/1`.
@external(erlang, "codemode_ffi", "socket_close")
pub fn close(socket: Socket) -> Nil

/// Closes a listener, unblocking any accept in flight. Idempotent from
/// the caller's view; does not unlink the socket file.
///
/// Uses `gen_tcp:close/1`.
@external(erlang, "codemode_ffi", "listener_close")
pub fn close_listener(listener: Listener) -> Nil
