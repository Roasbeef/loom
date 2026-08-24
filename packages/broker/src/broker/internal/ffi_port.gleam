//// Port and filesystem externals for the exec pool.
////
//// FFI confinement (spec §0.2): every `@external` the exec pool needs
//// lives here, backed by `broker_ffi.erl`. `broker/exec` consumes these
//// through its transport seam, so pool logic is testable with in-process
//// fakes that never touch a real port.

import gleam/dynamic.{type Dynamic}
import gleam/erlang/port.{type Port}

/// One normalized message from a helper port, produced by `port_event`.
pub type PortEvent {
  /// A chunk of the helper's stdout reached us. Invariant: raw protocol
  /// bytes, not yet deframed.
  PortBytes(data: BitArray)
  /// The helper process exited with this OS status.
  PortClosed(status: Int)
  /// A message matched the port selector but was not a recognised port
  /// message shape; ignored by the pool.
  PortJunk
}

/// Spawns an executable with arguments as an Erlang port in binary
/// stream mode with exit-status reporting.
///
/// Uses `erlang:open_port/2` with `spawn_executable`; there is no other
/// non-NIF way to stream to a child process from the BEAM. The caller
/// owns framing (stream mode) and must select on the port for
/// `PortEvent` messages.
@external(erlang, "broker_ffi", "open_helper")
pub fn open_helper(executable: String, args: List(String)) -> Result(Port, Nil)

/// Writes bytes to the port's stdin. Errors once the port is closed.
///
/// Uses `erlang:port_command/2`; the shim converts its badarg on a dead
/// port into `Error(Nil)` so channel death settles in-band.
@external(erlang, "broker_ffi", "port_send")
pub fn port_send(port: Port, bytes: BitArray) -> Result(Nil, Nil)

/// Closes the port, idempotently. The helper treats stdio close as an
/// order to reap any running jail.
///
/// Uses `erlang:port_close/1` via a shim that absorbs the badarg an
/// already-closed port raises.
@external(erlang, "broker_ffi", "close_port")
pub fn close_port(port: Port) -> Nil

/// Reports the OS pid of the port's child process, when it is running.
///
/// Uses `erlang:port_info/2`; kept so the broker-side cancel escalation
/// can SIGKILL the helper as a last resort.
@external(erlang, "broker_ffi", "port_os_pid")
pub fn port_os_pid(port: Port) -> Result(Int, Nil)

/// Sends SIGKILL to an OS process by pid. No-op for pids `<= 1`.
///
/// Uses `os:cmd/1` running `kill -KILL`; the BEAM offers no direct
/// kill(2) without a NIF. Belt-and-braces only: the helper's own
/// TERM-then-KILL ladder is the primary mechanism.
@external(erlang, "broker_ffi", "kill_os_process")
pub fn kill_os_process(os_pid: Int) -> Nil

/// Creates `dir` with mode 0700 if needed, then writes `name` inside it
/// exclusively and tightens the file to mode 0600, returning the full
/// path. Used to deliver the sandbox policy to a freshly spawned helper
/// via an fd-3 shell redirection (see `broker/exec`).
///
/// Uses `filelib:ensure_path/1`, `file:write_file/3`, and
/// `file:change_mode/2`; policy delivery crosses the filesystem, so no
/// pure alternative exists.
@external(erlang, "broker_ffi", "write_private_file")
pub fn write_private_file(
  dir: String,
  name: String,
  bytes: BitArray,
) -> Result(String, Nil)

/// Deletes a file, idempotently. Used to unlink the temp policy file as
/// soon as the helper's hello proves it has been read.
///
/// Uses `file:delete/1`; filesystem cleanup has no pure alternative.
@external(erlang, "broker_ffi", "delete_file")
pub fn delete_file(path: String) -> Nil

/// Normalizes a raw port message (delivered by a record selector on the
/// port) into a `PortEvent`.
///
/// Uses an Erlang shim because the message arrives as a `Dynamic` whose
/// `{Port, {data, Bin}}` shape only Erlang pattern matching can take
/// apart without partial decoders.
@external(erlang, "broker_ffi", "port_event")
pub fn port_event(message: Dynamic) -> PortEvent
