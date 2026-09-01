//// Operating-system primitives for local server bootstrap.
////
//// The bootstrap policy stays in `tui/bootstrap`; this module confines the
//// ambient filesystem, process, socket, clock, and cryptographic operations
//// which have no pure Gleam implementation. Each external is backed by the
//// package's single `tui_ffi.erl` shim.

/// An operating-system launch lock held by a helper port.
pub type LaunchLock

/// A detached server process retained as a port while bootstrap waits.
pub type ServerProcess

/// One operating-system process identity observation.
pub type ProcessIdentity {
  ProcessPresent(birth: String)
  ProcessAbsent
}

/// Returns the current Unix time in milliseconds.
///
/// Uses OTP `erlang:system_time/1`; bootstrap compares only timestamps minted
/// by this same clock during one launch attempt.
@external(erlang, "tui_ffi", "system_time_ms")
pub fn system_time_ms() -> Int

/// Stops every OTP logger handler from writing to the terminal.
///
/// Uses OTP `logger:set_primary_config/2` with level `none`. Once etui owns
/// the alternate screen, a dependency's error report or a crash report has
/// nowhere to go except over the rendered frame, where it stays until those
/// cells repaint; a stale endpoint probe during a session switch is one
/// producer. Failures the operator must see already reach the transcript as
/// typed errors.
@external(erlang, "tui_ffi", "silence_logger")
pub fn silence_logger() -> Nil

/// Returns monotonic milliseconds for process-local elapsed-time bounds.
///
/// Uses OTP `erlang:monotonic_time/1`; the value has no wall-clock meaning and
/// is valid only for deadline comparisons within this VM.
@external(erlang, "tui_ffi", "monotonic_time_ms")
pub fn monotonic_time_ms() -> Int

/// Returns a cryptographic SHA-256 digest.
///
/// Uses OTP `crypto:hash/2`; a workspace digest must remain stable across
/// processes and cannot use the BEAM's runtime-local term hash.
@external(erlang, "tui_ffi", "sha256")
pub fn sha256(bytes: BitArray) -> BitArray

/// Returns one environment variable when present.
///
/// Uses OTP `os:getenv/1`; explicit environment configuration is part of the
/// launcher interface and has no pure source.
@external(erlang, "tui_ffi", "getenv")
pub fn getenv(name: String) -> Result(String, Nil)

/// Resolves a directory to its absolute, symlink-free path.
///
/// Uses the platform `realpath` executable after `filelib:is_dir/1`; pathname
/// canonicalization is an operating-system query with no pure equivalent.
@external(erlang, "tui_ffi", "canonical_directory")
pub fn canonical_directory(path: String) -> Result(String, String)

/// Resolves an existing path through every symbolic link.
///
/// This is a mechanical operating-system primitive. Bootstrap decides when an
/// existing file or its parent directory is the identity-bearing object.
@external(erlang, "tui_ffi", "canonical_path")
pub fn canonical_path(path: String) -> Result(String, String)

/// Reports whether a path entry exists without following its final link.
@external(erlang, "tui_ffi", "path_exists")
pub fn path_exists(path: String) -> Bool

/// Resolves a path against the current working directory.
///
/// Uses OTP `filename:absname/1`; the process working directory is ambient
/// operating-system state.
@external(erlang, "tui_ffi", "absolute_path")
pub fn absolute_path(path: String) -> Result(String, String)

/// Creates or verifies a private directory owned by this user.
///
/// Uses OTP `file` operations and POSIX ownership/mode fields. The state root
/// must not follow a final symlink or expose launch credentials to peers.
@external(erlang, "tui_ffi", "ensure_private_directory")
pub fn ensure_private_directory(path: String) -> Result(Nil, String)

/// Lists one directory only when its entry count is within `limit`.
///
/// Uses OTP `file:list_dir/1`; the bound limits the launcher records returned
/// to Gleam and therefore the number of endpoint files the client will parse.
@external(erlang, "tui_ffi", "list_directory_bounded")
pub fn list_directory_bounded(
  path: String,
  limit: Int,
) -> Result(List(String), String)

/// Attempts to acquire an automatically released cross-process file lock.
///
/// Uses the platform `lockf` or `flock` utility behind an Erlang port. The
/// helper holds the kernel lock until this opaque port is closed or the VM
/// exits, preserving crash release without a stale lockfile protocol. Its
/// privileged shell uses only builtins while holding the lock, so inherited
/// functions and `PATH` entries cannot make it release early.
@external(erlang, "tui_ffi", "try_launch_lock")
pub fn try_launch_lock(path: String) -> Result(LaunchLock, String)

/// Releases a launch lock.
///
/// Uses OTP `erlang:port_close/1`; closing the helper port releases its kernel
/// file lock.
@external(erlang, "tui_ffi", "release_launch_lock")
pub fn release_launch_lock(lock: LaunchLock) -> Nil

/// Reads one regular file up to a fixed byte limit.
///
/// Uses OTP raw file I/O and `file:read_file_info/2`; the bound prevents a
/// malformed endpoint hint from allocating without limit.
@external(erlang, "tui_ffi", "read_regular_bounded")
pub fn read_regular_bounded(
  path: String,
  limit: Int,
) -> Result(BitArray, String)

/// Reads a private regular file up to a fixed byte limit.
///
/// Uses OTP raw file I/O plus POSIX owner and mode fields. Bearer tokens are
/// refused when another user can read the file.
@external(erlang, "tui_ffi", "read_private_bounded")
pub fn read_private_bounded(
  path: String,
  limit: Int,
) -> Result(BitArray, String)

/// Atomically replaces a private text file.
///
/// Uses OTP `file:open/2`, `file:sync/1`, and `file:rename/2`; a reader sees
/// either the prior complete endpoint record or the next one.
@external(erlang, "tui_ffi", "atomic_write_private")
pub fn atomic_write_private(
  path: String,
  contents: String,
) -> Result(Nil, String)

/// Finds an executable, resolving explicit paths without fallback.
///
/// Uses OTP `os:find_executable/1` and POSIX executable mode checks. The
/// launcher needs the exact executable it will later pass to `open_port/2`.
@external(erlang, "tui_ffi", "find_executable")
pub fn find_executable(candidate: String) -> Result(String, String)

/// Reports whether an exact path is a regular executable file.
///
/// Uses OTP `file:read_file_info/2`; there is no pure answer for file type or
/// mode bits.
@external(erlang, "tui_ffi", "is_executable_file")
pub fn is_executable_file(path: String) -> Bool

/// Reserves and releases one IPv4 loopback port.
///
/// Uses OTP `gen_tcp:listen/2` with port zero. The returned port is a hint;
/// the server bind remains authoritative and a bind race fails visibly.
@external(erlang, "tui_ffi", "reserve_loopback_port")
pub fn reserve_loopback_port() -> Result(Int, String)

/// Starts a paused server wrapper with output directed to a private log.
///
/// Uses OTP `open_port/2` with `spawn_executable`. The wrapper waits for one
/// release byte before it replaces itself with the daemon, preserving its pid
/// and birth identity. Privileged shell mode ignores inherited shell functions;
/// if the launcher dies first, port EOF makes the wrapper exit.
@external(erlang, "tui_ffi", "spawn_server")
pub fn spawn_server(
  executable: String,
  arguments: List(String),
  working_directory: String,
  log_path: String,
) -> Result(#(ServerProcess, Int), String)

/// Releases a paused wrapper to replace itself with the daemon.
///
/// Uses OTP `erlang:port_command/2` after the endpoint has durably recorded the
/// wrapper's pid and birth identity. An error leaves the wrapper unreleased.
@external(erlang, "tui_ffi", "release_server_process")
pub fn release_server_process(process: ServerProcess) -> Result(Nil, String)

/// Closes the retained server port without terminating the detached process.
///
/// Uses OTP `erlang:port_close/1`. The external process remains re-parented
/// and alive; this only releases the launcher's port resource.
@external(erlang, "tui_ffi", "close_server_process")
pub fn close_server_process(process: ServerProcess) -> Nil

/// Sends SIGTERM to one detached process group for test cleanup.
///
/// Uses the platform `kill` executable with a negative process-group id. The
/// production bootstrap never signals a numeric pid because reuse cannot be
/// excluded atomically on every supported platform.
@external(erlang, "tui_ffi", "terminate_process_group")
pub fn terminate_process_group(pid: Int) -> Nil

/// Returns a birth-qualified identity or confirms that the process is absent.
///
/// Linux proves procfs is observable before reading `/proc/<pid>/stat` plus the
/// kernel boot id; Darwin asks `ps` for the full start time. Absence is distinct
/// from an observation failure so stale endpoints can be replaced without
/// treating uncertainty as death.
@external(erlang, "tui_ffi", "process_identity")
pub fn process_identity(pid: Int) -> Result(ProcessIdentity, String)

/// Returns a bounded tail of a current server log.
///
/// Uses OTP raw file I/O and modification time. Diagnostics must not turn a
/// startup failure into an unbounded read.
@external(erlang, "tui_ffi", "current_log_tail")
pub fn current_log_tail(
  path: String,
  started_at_ms: Int,
  limit: Int,
) -> Result(String, Nil)
