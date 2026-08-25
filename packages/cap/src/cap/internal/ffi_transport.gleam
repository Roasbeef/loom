//// The satellite's production transport primitives: the AF_UNIX socket
//// carrying the capability channel, plus the two environment/file reads
//// that locate the socket and the cap token.
////
//// FFI confinement (spec §0.2): every `@external` in the cap package
//// lives in a `cap/internal/ffi_*.gleam` module and binds `cap_ffi.erl`.
//// This module is the whole of the satellite's transport impurity; the
//// runtime (`cap/runtime`) wraps these into the injected `Transport` a
//// program never sees, and every test substitutes in-process functions
//// for them, so the boot logic stays pure and testable without a socket.

/// An open AF_UNIX stream socket. External type, never `Dynamic`: it names
/// the Erlang `gen_tcp` socket without exposing its structure to Gleam.
pub type Socket

/// Reads an environment variable.
///
/// Uses `os:getenv/1`; there is no pure alternative, and the boot module
/// needs the host-supplied socket path and token-file path from the jail's
/// environment.
@external(erlang, "cap_ffi", "getenv")
pub fn getenv(name: String) -> Result(String, Nil)

/// Reads a file's whole contents as bytes.
///
/// Uses `file:read_file/1`; the cap token is delivered as a private
/// mode-0600 file bind-mounted into the jail, read once at boot.
@external(erlang, "cap_ffi", "read_file")
pub fn read_file(path: String) -> Result(BitArray, Nil)

/// Connects to the host's capability channel over an AF_UNIX stream
/// socket at `path`.
///
/// Uses `gen_tcp:connect/3` with a `{local, Path}` address in passive,
/// raw-packet, binary mode — an AF_UNIX socket, not AF_INET, so it is the
/// one link the jail permits and never crosses distribution. Passive mode
/// hands frame boundaries to `cap/internal/inbound`, not the port driver.
@external(erlang, "cap_ffi", "connect_unix")
pub fn connect_unix(path: String) -> Result(Socket, Nil)

/// Blocks until some bytes arrive on the socket, returning whatever is
/// available. `Error(Nil)` means the peer closed the channel or the socket
/// faulted — the reader treats it as end of stream.
///
/// Uses `gen_tcp:recv/2` with length 0 (return available bytes) on a
/// passive socket.
@external(erlang, "cap_ffi", "socket_recv")
pub fn socket_recv(socket: Socket) -> Result(BitArray, Nil)

/// Writes all of `bytes` to the socket. `Error(Nil)` on a closed or
/// faulted socket; the channel actor settles the effect in-band rather
/// than crashing.
///
/// Uses `gen_tcp:send/2`.
@external(erlang, "cap_ffi", "socket_send")
pub fn socket_send(socket: Socket, bytes: BitArray) -> Result(Nil, Nil)

/// Closes the socket. Idempotent from the caller's view.
///
/// Uses `gen_tcp:close/1`.
@external(erlang, "cap_ffi", "socket_close")
pub fn socket_close(socket: Socket) -> Nil
