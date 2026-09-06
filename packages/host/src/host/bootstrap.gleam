//// Shared operating-system primitives for local server ownership and startup.
////
//// Callers keep their startup policy in Gleam. This module exposes the existing
//// filesystem, lock, process, clock, and crypto boundary used by the terminal
//// launcher and the daemon. External calls stay in host/internal/ffi_bootstrap.

import gleam/erlang/process.{type Monitor}
import gleam/result
import host/internal/ffi_bootstrap as ffi

/// An operating-system launch lock held by a helper port.
pub type LaunchLock =
  ffi.LaunchLock

/// Monitors the original lock-helper port without transferring its ownership.
///
/// The root installs this monitor before publishing readiness. Unexpected port
/// death means the kernel lock may have been released, so readiness must end.
///
/// ## Examples
///
/// ```gleam
/// let watch = bootstrap.lock_monitor(lock)
/// ```
pub fn lock_monitor(lock: LaunchLock) -> Monitor {
  ffi.lock_monitor(lock)
}

/// A detached server process retained as a port while bootstrap waits.
pub type ServerProcess =
  ffi.ServerProcess

/// Returns the operating-system PID of this whole BEAM VM.
///
/// ## Examples
///
/// ```gleam
/// // bootstrap.process_identity(bootstrap.current_process_id())
/// ```
pub fn current_process_id() -> Int {
  ffi.current_process_id()
}

/// One operating-system process identity observation.
pub type ProcessIdentity {
  /// The process exists with this platform-qualified birth marker.
  ProcessPresent(birth: String)

  /// The platform confirmed that no such process exists.
  ProcessAbsent
}

/// Returns the current Unix time in milliseconds.
///
/// Uses OTP `erlang:system_time/1`; bootstrap compares only timestamps minted
/// by this same clock during one launch attempt.
///
/// ## Examples
///
/// ```gleam
/// // bootstrap.system_time_ms()
/// ```
pub fn system_time_ms() -> Int {
  ffi.system_time_ms()
}

/// Returns monotonic milliseconds for process-local elapsed-time bounds.
///
/// Uses OTP `erlang:monotonic_time/1`; the value has no wall-clock meaning and
/// is valid only for deadline comparisons within this VM.
///
/// ## Examples
///
/// ```gleam
/// // bootstrap.monotonic_time_ms()
/// ```
pub fn monotonic_time_ms() -> Int {
  ffi.monotonic_time_ms()
}

/// Returns a cryptographic SHA-256 digest.
///
/// Uses OTP `crypto:hash/2`; a workspace digest must remain stable across
/// processes and cannot use the BEAM's runtime-local term hash.
///
/// ## Examples
///
/// ```gleam
/// // bootstrap.sha256(bytes)
/// ```
pub fn sha256(bytes: BitArray) -> BitArray {
  ffi.sha256(bytes)
}

/// Returns one environment variable when present.
///
/// Uses OTP `os:getenv/1`; explicit environment configuration is part of the
/// launcher interface and has no pure source.
///
/// ## Examples
///
/// ```gleam
/// // bootstrap.getenv(name)
/// ```
pub fn getenv(name: String) -> Result(String, Nil) {
  ffi.getenv(name)
}

/// Resolves a directory to its absolute, symlink-free path.
///
/// Uses the platform `realpath` executable after `filelib:is_dir/1`; pathname
/// canonicalization is an operating-system query with no pure equivalent.
///
/// ## Examples
///
/// ```gleam
/// // bootstrap.canonical_directory(path)
/// ```
pub fn canonical_directory(path: String) -> Result(String, String) {
  ffi.canonical_directory(path)
}

/// Resolves an existing path through every symbolic link.
///
/// This is a mechanical operating-system primitive. Bootstrap decides when an
/// existing file or its parent directory is the identity-bearing object.
///
/// ## Examples
///
/// ```gleam
/// // bootstrap.canonical_path(path)
/// ```
pub fn canonical_path(path: String) -> Result(String, String) {
  ffi.canonical_path(path)
}

/// Reports whether a path entry exists without following its final link.
///
/// ## Examples
///
/// ```gleam
/// // bootstrap.path_exists(path)
/// ```
pub fn path_exists(path: String) -> Bool {
  ffi.path_exists(path)
}

/// Resolves a path against the current working directory.
///
/// Uses OTP `filename:absname/1`; the process working directory is ambient
/// operating-system state.
///
/// ## Examples
///
/// ```gleam
/// // bootstrap.absolute_path(path)
/// ```
pub fn absolute_path(path: String) -> Result(String, String) {
  ffi.absolute_path(path)
}

/// Creates or verifies a private directory owned by this user.
///
/// Uses OTP `file` operations and POSIX ownership/mode fields. The state root
/// must not follow a final symlink or expose launch credentials to peers.
///
/// ## Examples
///
/// ```gleam
/// // bootstrap.ensure_private_directory(path)
/// ```
pub fn ensure_private_directory(path: String) -> Result(Nil, String) {
  ffi.ensure_private_directory(path)
}

/// Lists one directory only when its entry count is within `limit`.
///
/// Uses OTP `file:list_dir/1`; the bound limits the launcher records returned
/// to Gleam and therefore the number of endpoint files the client will parse.
///
/// ## Examples
///
/// ```gleam
/// // bootstrap.list_directory_bounded(path, limit)
/// ```
pub fn list_directory_bounded(
  path: String,
  limit: Int,
) -> Result(List(String), String) {
  ffi.list_directory_bounded(path, limit)
}

/// Attempts to acquire an automatically released cross-process file lock.
///
/// Uses the platform `lockf` or `flock` utility behind an Erlang port. The
/// helper holds the kernel lock until this opaque port is closed or the VM
/// exits, preserving crash release without a stale lockfile protocol. Its
/// privileged shell uses only builtins while holding the lock, so inherited
/// functions and `PATH` entries cannot make it release early.
///
/// ## Examples
///
/// ```gleam
/// // bootstrap.try_launch_lock(path)
/// ```
pub fn try_launch_lock(path: String) -> Result(LaunchLock, String) {
  ffi.try_launch_lock(path)
}

/// Releases a launch lock.
///
/// Uses OTP `erlang:port_close/1`; closing the helper port releases its kernel
/// file lock.
///
/// ## Examples
///
/// ```gleam
/// // bootstrap.release_launch_lock(lock)
/// ```
pub fn release_launch_lock(lock: LaunchLock) -> Nil {
  ffi.release_launch_lock(lock)
}

/// Reads one regular file up to a fixed byte limit.
///
/// Uses OTP raw file I/O and `file:read_file_info/2`; the bound prevents a
/// malformed endpoint hint from allocating without limit.
///
/// ## Examples
///
/// ```gleam
/// // bootstrap.read_regular_bounded(path, limit)
/// ```
pub fn read_regular_bounded(
  path: String,
  limit: Int,
) -> Result(BitArray, String) {
  ffi.read_regular_bounded(path, limit)
}

/// Reads a private regular file up to a fixed byte limit.
///
/// Uses OTP raw file I/O plus POSIX owner and mode fields. Bearer tokens are
/// refused when another user can read the file.
///
/// ## Examples
///
/// ```gleam
/// // bootstrap.read_private_bounded(path, limit)
/// ```
pub fn read_private_bounded(
  path: String,
  limit: Int,
) -> Result(BitArray, String) {
  ffi.read_private_bounded(path, limit)
}

/// Atomically replaces a private text file.
///
/// Uses OTP `file:open/2`, `file:sync/1`, and `file:rename/2`; a reader sees
/// either the prior complete endpoint record or the next one.
///
/// ## Examples
///
/// ```gleam
/// // bootstrap.atomic_write_private(path, contents)
/// ```
pub fn atomic_write_private(
  path: String,
  contents: String,
) -> Result(Nil, String) {
  ffi.atomic_write_private(path, contents)
}

/// Finds an executable, resolving explicit paths without fallback.
///
/// Uses OTP `os:find_executable/1` and POSIX executable mode checks. The
/// launcher needs the exact executable it will later pass to `open_port/2`.
///
/// ## Examples
///
/// ```gleam
/// // bootstrap.find_executable(candidate)
/// ```
pub fn find_executable(candidate: String) -> Result(String, String) {
  ffi.find_executable(candidate)
}

/// Reports whether an exact path is a regular executable file.
///
/// Uses OTP `file:read_file_info/2`; there is no pure answer for file type or
/// mode bits.
///
/// ## Examples
///
/// ```gleam
/// // bootstrap.is_executable_file(path)
/// ```
pub fn is_executable_file(path: String) -> Bool {
  ffi.is_executable_file(path)
}

/// Reserves and releases one IPv4 loopback port.
///
/// Uses OTP `gen_tcp:listen/2` with port zero. The returned port is a hint;
/// the server bind remains authoritative and a bind race fails visibly.
///
/// ## Examples
///
/// ```gleam
/// // bootstrap.reserve_loopback_port()
/// ```
pub fn reserve_loopback_port() -> Result(Int, String) {
  ffi.reserve_loopback_port()
}

/// Starts a paused server wrapper with output directed to a private log.
///
/// Uses OTP `open_port/2` with `spawn_executable`. The wrapper waits for one
/// release byte before it replaces itself with the daemon, preserving its pid
/// and birth identity. Privileged shell mode ignores inherited shell functions;
/// if the launcher dies first, port EOF makes the wrapper exit.
///
/// ## Examples
///
/// ```gleam
/// // bootstrap.spawn_server(executable, arguments, working_directory, log_path)
/// ```
pub fn spawn_server(
  executable: String,
  arguments: List(String),
  working_directory: String,
  log_path: String,
) -> Result(#(ServerProcess, Int), String) {
  ffi.spawn_server(executable, arguments, working_directory, log_path)
}

/// Releases a paused wrapper to replace itself with the daemon.
///
/// Uses OTP `erlang:port_command/2` after the endpoint has durably recorded the
/// wrapper's pid and birth identity. An error leaves the wrapper unreleased.
///
/// ## Examples
///
/// ```gleam
/// // bootstrap.release_server_process(process)
/// ```
pub fn release_server_process(process: ServerProcess) -> Result(Nil, String) {
  ffi.release_server_process(process)
}

/// Closes the retained server port without terminating the detached process.
///
/// Uses OTP `erlang:port_close/1`. The external process remains re-parented
/// and alive; this only releases the launcher's port resource.
///
/// ## Examples
///
/// ```gleam
/// // bootstrap.close_server_process(process)
/// ```
pub fn close_server_process(process: ServerProcess) -> Nil {
  ffi.close_server_process(process)
}

/// Sends SIGTERM to one detached process group for test cleanup.
///
/// Uses the platform `kill` executable with a negative process-group id. The
/// production bootstrap never signals a numeric pid because reuse cannot be
/// excluded atomically on every supported platform.
///
/// ## Examples
///
/// ```gleam
/// // bootstrap.terminate_process_group(pid)
/// ```
pub fn terminate_process_group(pid: Int) -> Nil {
  ffi.terminate_process_group(pid)
}

/// Returns a birth-qualified identity or confirms that the process is absent.
///
/// Linux proves procfs is observable before reading `/proc/<pid>/stat` plus the
/// kernel boot id; Darwin asks `ps` for the full start time. Absence is distinct
/// from an observation failure so stale endpoints can be replaced without
/// treating uncertainty as death.
///
/// ## Examples
///
/// ```gleam
/// // bootstrap.process_identity(pid)
/// ```
pub fn process_identity(pid: Int) -> Result(ProcessIdentity, String) {
  ffi.process_identity(pid)
  |> result.map(fn(identity) {
    case identity {
      ffi.ProcessPresent(birth) -> ProcessPresent(birth)
      ffi.ProcessAbsent -> ProcessAbsent
    }
  })
}

/// Returns a bounded tail of a current server log.
///
/// Uses OTP raw file I/O and modification time. Diagnostics must not turn a
/// startup failure into an unbounded read.
///
/// ## Examples
///
/// ```gleam
/// // bootstrap.current_log_tail(path, started_at_ms, limit)
/// ```
pub fn current_log_tail(
  path: String,
  started_at_ms: Int,
  limit: Int,
) -> Result(String, Nil) {
  ffi.current_log_tail(path, started_at_ms, limit)
}
