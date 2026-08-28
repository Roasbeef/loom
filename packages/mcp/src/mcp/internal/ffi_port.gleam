//// Port externals for the MCP client's production transport: spawning an
//// MCP server as a child OS process and speaking to it over stdio.
////
//// FFI confinement (spec §0.2): every `@external` in the mcp package
//// lives here and binds `mcp_ffi.erl`. `mcp/transport` consumes these
//// behind its `Transport` seam, so the client actor stays testable with
//// in-process fakes that never touch a real port — the same arrangement
//// as `broker/internal/ffi_port` and its exec pool.

import gleam/dynamic.{type Dynamic}
import gleam/erlang/port.{type Port}
import gleam/option.{type Option}

/// One normalized message from a server port, produced by `port_event`.
pub type PortEvent {
  /// A chunk of the server's stdout reached us. Invariant: raw bytes at
  /// whatever boundary the pipe delivered; not yet lines, not yet UTF-8.
  PortBytes(data: BitArray)
  /// The server process exited with this OS status.
  PortClosed(status: Int)
  /// A message matched the port selector but was not a recognised port
  /// message shape; ignored by the client.
  PortJunk
}

/// Spawns an executable with argv, extra environment pairs, and an
/// optional working directory, as an Erlang port in binary stream mode
/// with exit-status reporting. The child's stdin and stdout are the wire;
/// stderr is deliberately left alone (see `mcp/transport` for why).
///
/// Uses `erlang:open_port/2` with `spawn_executable`; there is no other
/// non-NIF way to stream to a child process from the BEAM. argv is a
/// list, never a shell string, so nothing here is shell-interpretable.
///
/// The error carries the failure's own reason as a short lowercase
/// string — `"enoent"` for a missing executable, `"eacces"` for one that
/// cannot be run, the class and a bounded term for anything else. That
/// distinction is load-bearing rather than cosmetic: the port tests skip
/// on an absent binary, and a blanket `Error(Nil)` let an FFI regression
/// wear the same clothes as a host without `/bin/cat`.
@external(erlang, "mcp_ffi", "open_stdio")
pub fn open_stdio(
  executable: String,
  args: List(String),
  env: List(#(String, String)),
  directory: Option(String),
) -> Result(Port, String)

/// Writes one already-framed line to the server's stdin. Errors once the
/// port is closed, so a dead server settles in-band rather than crashing
/// the writer.
///
/// Uses `erlang:port_command/2` via a shim that converts its badarg on a
/// dead port into `Error(Nil)`.
@external(erlang, "mcp_ffi", "port_send")
pub fn port_send(port: Port, line: String) -> Result(Nil, Nil)

/// Closes the port, idempotently. Closing the port closes the server's
/// stdin, which is the stdio transport's shutdown signal.
///
/// Uses `erlang:port_close/1` via a shim that absorbs the badarg an
/// already-closed port raises.
@external(erlang, "mcp_ffi", "close_port")
pub fn close_port(port: Port) -> Nil

/// Reports the OS pid of the port's child process, when it is running.
///
/// Uses `erlang:port_info/2`; kept so `stop` can kill a server that does
/// not exit when its stdin closes.
@external(erlang, "mcp_ffi", "port_os_pid")
pub fn port_os_pid(port: Port) -> Result(Int, Nil)

/// Sends SIGKILL to an OS process by pid. No-op for pids `<= 1`.
///
/// Uses `os:cmd/1` running `kill -KILL`; the BEAM offers no direct
/// kill(2) without a NIF. Belt-and-braces after the stdin close — a
/// well-behaved MCP server exits on EOF and is gone before this runs.
@external(erlang, "mcp_ffi", "kill_os_process")
pub fn kill_os_process(os_pid: Int) -> Nil

/// Normalizes a raw port message (delivered by a record selector on the
/// port) into a `PortEvent`.
///
/// Uses an Erlang shim because the message arrives as a `Dynamic` whose
/// `{Port, {data, Bin}}` shape only Erlang pattern matching can take
/// apart without partial decoders.
@external(erlang, "mcp_ffi", "port_event")
pub fn port_event(message: Dynamic) -> PortEvent
