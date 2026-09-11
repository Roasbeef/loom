//// Shared operating-system primitives for local server ownership and startup.
////
//// Callers keep their startup policy in Gleam. This module is the whole of
//// the filesystem, lock, process, clock, and crypto boundary the terminal
//// launcher and the daemon share, and it is the only module in this package
//// that declares an `@external`.
////
//// The house rule is that custom Erlang is a last resort, so the split here
//// is deliberate. Everything a published Gleam package already expresses —
//// clocks, digests, the environment, `stat`, directory listing, permission
//// bits — is written in Gleam over `gleam_crypto`, `gleam_time`, `envoy`,
//// `simplifile`, `filepath` and `weft/poll`. What remains in
//// `host_bootstrap_ffi.erl` is what no such package reaches: cross-process
//// advisory file locking through a helper port, `open_port` process launch
//// and its release, a positioned bounded read, an exclusive-create atomic
//// rename, `realpath`, `os:find_executable`, procfs and `ps` birth identity,
//// and `os:getpid`/`id -u`. Each of those is a mechanism with no library
//// equivalent; the policy around it lives here, in Gleam.

import envoy
import filepath
import gleam/bit_array
import gleam/bool
import gleam/crypto
import gleam/erlang/process.{type Monitor}
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import gleam/time/timestamp
import simplifile
import weft/poll

/// An operating-system launch lock held by a helper port.
pub type LaunchLock

/// A detached server process retained as a port while bootstrap waits.
pub type ServerProcess

/// One operating-system process identity observation.
///
/// The Erlang side returns exactly this shape, so no translation sits between
/// the observation and the caller.
pub type ProcessIdentity {
  /// The process exists with this platform-qualified birth marker.
  ProcessPresent(birth: String)

  /// The platform confirmed that no such process exists.
  ProcessAbsent
}

/// Which kind of thing `erlang:monitor/2` is being asked to watch.
type PortMonitorFlag {
  Port
}

// OTP monitors a port directly; no helper process or new Erlang shim is
// needed. `gleam_erlang` exposes the resulting `process.PortDown` variant but
// no public constructor for a port monitor, so the flag is spelled here.
@external(erlang, "erlang", "monitor")
fn monitor_port(kind: PortMonitorFlag, lock: LaunchLock) -> Monitor

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
  monitor_port(Port, lock)
}

/// Returns the operating-system PID of this whole BEAM VM.
///
/// Uses OTP `os:getpid/0`, which no Gleam package binds. The endpoint fences
/// the VM rather than one BEAM process inside it, so this is the pid a peer
/// launcher observes for birth identity.
///
/// ## Examples
///
/// ```gleam
/// // bootstrap.process_identity(bootstrap.current_process_id())
/// ```
@external(erlang, "host_bootstrap_ffi", "current_process_id")
pub fn current_process_id() -> Int

/// Returns the current Unix time in milliseconds.
///
/// Bootstrap compares only timestamps minted by this same clock during one
/// launch attempt, and publishes one of them in the starting record so a later
/// launcher can ask how much of the budget has been spent.
///
/// ## Examples
///
/// ```gleam
/// // bootstrap.system_time_ms()
/// ```
pub fn system_time_ms() -> Int {
  let #(seconds, nanoseconds) =
    timestamp.system_time()
    |> timestamp.to_unix_seconds_and_nanoseconds

  seconds * 1000 + nanoseconds / 1_000_000
}

/// Returns monotonic milliseconds for process-local elapsed-time bounds.
///
/// This is `weft/poll`'s own monotonic clock, so a deadline computed here and
/// a `poll.until` wait elsewhere in the same launch are measured on one base.
/// The value has no wall-clock meaning and is valid only within this VM.
///
/// ## Examples
///
/// ```gleam
/// // bootstrap.monotonic_time_ms()
/// ```
pub fn monotonic_time_ms() -> Int {
  let clock = poll.monotonic()
  clock.now()
}

/// Returns a cryptographic SHA-256 digest.
///
/// A workspace digest must remain stable across processes, so it cannot use
/// the BEAM's runtime-local term hash.
///
/// ## Examples
///
/// ```gleam
/// // bootstrap.sha256(bytes)
/// ```
pub fn sha256(bytes: BitArray) -> BitArray {
  crypto.hash(crypto.Sha256, bytes)
}

/// Returns one environment variable when present.
///
/// Explicit environment configuration is part of the launcher interface and
/// has no pure source.
///
/// ## Examples
///
/// ```gleam
/// // bootstrap.getenv(name)
/// ```
pub fn getenv(name: String) -> Result(String, Nil) {
  envoy.get(name)
}

/// Resolves a directory to its absolute, symlink-free path.
///
/// Uses the platform `realpath` executable. Pathname canonicalization is an
/// operating-system query with no library equivalent: `simplifile.resolve` is
/// `filename:absname` plus a lexical `..` fold, which is precisely the answer
/// symbolic links make wrong.
///
/// ## Examples
///
/// ```gleam
/// // bootstrap.canonical_directory(path)
/// ```
@external(erlang, "host_bootstrap_ffi", "canonical_directory")
pub fn canonical_directory(path: String) -> Result(String, String)

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
@external(erlang, "host_bootstrap_ffi", "canonical_path")
pub fn canonical_path(path: String) -> Result(String, String)

/// Reports whether a path entry exists without following its final link.
///
/// A dangling symbolic link therefore counts as an existing entry, which is
/// what a launcher deciding whether to replace a path needs to know.
///
/// ## Examples
///
/// ```gleam
/// // bootstrap.path_exists(path)
/// ```
pub fn path_exists(path: String) -> Bool {
  simplifile.link_info(path)
  |> result.is_ok
}

/// Resolves a path against the current working directory.
///
/// The working directory is ambient operating-system state. No `..` segment is
/// folded away: shortening a path lexically changes which directory it names
/// as soon as a symbolic link is on it, and callers that want the resolved
/// identity ask `canonical_path` for it.
///
/// ## Examples
///
/// ```gleam
/// // bootstrap.absolute_path(path)
/// ```
pub fn absolute_path(path: String) -> Result(String, String) {
  use <- bool.guard(when: filepath.is_absolute(path), return: Ok(path))

  simplifile.current_directory()
  |> result.map(filepath.join(_, path))
  |> result.map_error(simplifile.describe_error)
}

/// Creates or verifies a private directory owned by this user.
///
/// The state root holds launch credentials, so its final component must be a
/// real directory this user owns rather than a link into somebody else's tree,
/// and it is forced to `0700` on every check rather than only at creation.
///
/// ## Examples
///
/// ```gleam
/// // bootstrap.ensure_private_directory(path)
/// ```
pub fn ensure_private_directory(path: String) -> Result(Nil, String) {
  use Nil <- result.try(
    simplifile.create_directory_all(path)
    |> result.map_error(simplifile.describe_error),
  )

  // `link_info` rather than `file_info`: a symbolic link whose target happens
  // to be a directory this user owns would otherwise pass, and the credential
  // written afterwards would land wherever the link points.
  use info <- result.try(
    simplifile.link_info(path)
    |> result.map_error(simplifile.describe_error),
  )
  use Nil <- result.try(case simplifile.file_info_type(info) {
    simplifile.Directory -> Ok(Nil)
    other -> Error("state path is not a directory: " <> string.inspect(other))
  })

  use uid <- result.try(current_uid())
  use Nil <- result.try(case info.user_id == uid {
    True -> Ok(Nil)
    False -> Error("state path is not owned by the current user: " <> path)
  })

  simplifile.set_permissions_octal(path, 0o700)
  |> result.map_error(simplifile.describe_error)
}

/// Lists one directory only when its entry count is within `limit`.
///
/// The bound limits the launcher records returned to Gleam and therefore the
/// number of endpoint files the client will parse.
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
  use <- bool.guard(
    when: limit < 0,
    return: Error("directory entry limit must be non-negative"),
  )

  use entries <- result.try(
    simplifile.read_directory(path)
    |> result.map_error(simplifile.describe_error),
  )

  // Nothing past the limit-th entry, asked without walking the whole list:
  // an oversized directory costs one listing and no records at all, rather
  // than an unbounded list handed to a caller that would then parse each one.
  case list.drop(entries, limit) {
    [] -> Ok(entries)
    [_, ..] -> Error("directory exceeds the entry limit")
  }
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
@external(erlang, "host_bootstrap_ffi", "try_launch_lock")
pub fn try_launch_lock(path: String) -> Result(LaunchLock, String)

/// Releases a launch lock.
///
/// Uses OTP `erlang:port_close/1` to close the helper port. The external holder
/// exits asynchronously and releases its kernel file lock, so callers that
/// reacquire the lock must use bounded acquisition rather than assume it is
/// already available when this function returns.
///
/// ## Examples
///
/// ```gleam
/// // bootstrap.release_launch_lock(lock)
/// ```
@external(erlang, "host_bootstrap_ffi", "release_launch_lock")
pub fn release_launch_lock(lock: LaunchLock) -> Nil

/// Reads no more than `bytes` from the beginning of one regular file.
///
/// `simplifile` offers only whole-file reads, so a positioned partial read has
/// no library expression. The bound lets a classifier inspect magic bytes
/// before admitting a whole file into memory.
///
/// ## Examples
///
/// ```gleam
/// // bootstrap.read_prefix(path, 16)
/// ```
@external(erlang, "host_bootstrap_ffi", "read_prefix")
pub fn read_prefix(path: String, bytes: Int) -> Result(BitArray, String)

/// Reads one regular file without ever retaining more than `limit` bytes.
///
/// The bound is enforced while reading and one byte past the limit is an
/// error, so growth after an earlier size check cannot turn a bounded read
/// into an unbounded allocation. That probe is the part no library expresses.
///
/// ## Examples
///
/// ```gleam
/// // bootstrap.read_bounded(path, limit)
/// ```
@external(erlang, "host_bootstrap_ffi", "read_bounded")
pub fn read_bounded(path: String, limit: Int) -> Result(BitArray, String)

/// Reads a private regular file up to a fixed byte limit.
///
/// Bearer tokens are refused when another user owns the file or when any
/// group or world bit is set, and the type is checked without following a
/// final link so a token cannot be read through somebody else's symlink.
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
  use info <- result.try(
    simplifile.link_info(path)
    |> result.map_error(simplifile.describe_error),
  )
  use Nil <- result.try(case simplifile.file_info_type(info) {
    simplifile.File -> Ok(Nil)
    _ -> Error("path is not a regular file")
  })

  use uid <- result.try(current_uid())
  use Nil <- result.try(case info.user_id == uid {
    True -> Ok(Nil)
    False -> Error("file is not owned by the current user")
  })

  // Group and world bits together are `0o077`; any of them set means somebody
  // other than the owner can reach the credential this file holds.
  use Nil <- result.try(
    case int.bitwise_and(simplifile.file_info_permissions_octal(info), 0o077) {
      0 -> Ok(Nil)
      _ -> Error("file is accessible to other users")
    },
  )

  read_bounded(path, limit)
}

/// Atomically replaces a private text file.
///
/// Uses OTP `file:open/2` with `exclusive`, `file:sync/1`, and `file:rename/2`;
/// a reader sees either the prior complete endpoint record or the next one.
/// `simplifile` has none of exclusive creation, an fsync, or a rename that
/// preserves that ordering, so the sequence stays in Erlang.
///
/// ## Examples
///
/// ```gleam
/// // bootstrap.atomic_write_private(path, contents)
/// ```
@external(erlang, "host_bootstrap_ffi", "atomic_write_private")
pub fn atomic_write_private(
  path: String,
  contents: String,
) -> Result(Nil, String)

/// Finds an executable, resolving explicit paths without fallback.
///
/// Uses OTP `os:find_executable/1`, which no Gleam package binds. The launcher
/// needs the exact executable it will later pass to `open_port/2`.
///
/// ## Examples
///
/// ```gleam
/// // bootstrap.find_executable(candidate)
/// ```
@external(erlang, "host_bootstrap_ffi", "find_executable")
pub fn find_executable(candidate: String) -> Result(String, String)

/// Reports whether an exact path is a regular executable file.
///
/// The link is followed, because what matters is whether the thing that will
/// be executed is executable, not whether the name given for it is a link.
///
/// ## Examples
///
/// ```gleam
/// // bootstrap.is_executable_file(path)
/// ```
pub fn is_executable_file(path: String) -> Bool {
  case simplifile.file_info(path) {
    Ok(info) ->
      simplifile.file_info_type(info) == simplifile.File
      && int.bitwise_and(simplifile.file_info_permissions_octal(info), 0o111)
      != 0
    Error(_) -> False
  }
}

/// What a path names, for a caller that needs a regular file and nothing else.
pub type PathKind {
  /// The path resolves to a regular file.
  RegularFile

  /// The path resolves to something else: a directory, a device, a socket.
  OtherEntry

  /// The path resolves to nothing, a dangling symbolic link included.
  NoEntry
}

/// Classifies a path as a regular file, another kind of entry, or nothing.
///
/// The link is followed, so a dangling symbolic link answers `NoEntry` rather
/// than the `path_exists` answer that a link is an entry. Callers that must
/// read a file want the three cases distinguished in one stat: a missing path
/// and a directory are different operator mistakes and deserve different
/// wording.
///
/// ## Examples
///
/// ```gleam
/// // bootstrap.path_kind(path)
/// ```
pub fn path_kind(path: String) -> PathKind {
  case simplifile.file_info(path) {
    Ok(info) ->
      case simplifile.file_info_type(info) {
        simplifile.File -> RegularFile
        simplifile.Directory | simplifile.Symlink | simplifile.Other ->
          OtherEntry
      }
    Error(_) -> NoEntry
  }
}

/// Reserves and releases one IPv4 loopback port.
///
/// Uses OTP `gen_tcp:listen/2` with port zero. The returned port is a hint;
/// the server bind remains authoritative and a bind race fails visibly. Only
/// the legacy per-workspace v1 launch path asks for one — the daemon endpoint
/// records the actual bound port instead — so this goes when that path does.
///
/// ## Examples
///
/// ```gleam
/// // bootstrap.reserve_loopback_port()
/// ```
@external(erlang, "host_bootstrap_ffi", "reserve_loopback_port")
pub fn reserve_loopback_port() -> Result(Int, String)

/// Starts a paused server wrapper with output directed to a private log.
///
/// Uses OTP `open_port/2` with `spawn_executable`. The wrapper waits for one
/// release byte before it replaces itself with the daemon, preserving its pid
/// and birth identity. Privileged shell mode ignores inherited shell functions;
/// if the launcher dies first, port EOF makes the wrapper exit.
///
/// The wrapper's environment is this VM's environment plus `LOOM_LOG`, not a
/// replacement for it: the daemon is expected to inherit provider credentials
/// and locale from whoever started the launcher.
///
/// ## Examples
///
/// ```gleam
/// // bootstrap.spawn_server(executable, arguments, working_directory, log_path)
/// ```
@external(erlang, "host_bootstrap_ffi", "spawn_server")
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
///
/// ## Examples
///
/// ```gleam
/// // bootstrap.release_server_process(process)
/// ```
@external(erlang, "host_bootstrap_ffi", "release_server_process")
pub fn release_server_process(process: ServerProcess) -> Result(Nil, String)

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
@external(erlang, "host_bootstrap_ffi", "close_server_process")
pub fn close_server_process(process: ServerProcess) -> Nil

/// Sends SIGTERM to one detached process group. **Test cleanup only.**
///
/// This is support for suites that start a real wrapper and must reap it; no
/// production path calls it, and none should. The production bootstrap never
/// signals a numeric pid because reuse cannot be excluded atomically on every
/// supported platform, and this function takes a bare `Int` rather than a
/// birth-qualified fence, so a recycled pid would be signalled as if it were
/// the original group leader. A fixture's pid comes straight from the wrapper
/// it just started, which is why that is tolerable there and nowhere else.
///
/// ## Examples
///
/// ```gleam
/// // bootstrap.terminate_process_group(pid)
/// ```
@external(erlang, "host_bootstrap_ffi", "terminate_process_group")
pub fn terminate_process_group(pid: Int) -> Nil

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
@external(erlang, "host_bootstrap_ffi", "process_identity")
pub fn process_identity(pid: Int) -> Result(ProcessIdentity, String)

/// Returns a bounded tail of a current server log.
///
/// Diagnostics must not turn a startup failure into an unbounded read, so the
/// tail is taken from a byte offset. That offset cannot know where a codepoint
/// begins, so the bytes cross the boundary as a `BitArray` and this function
/// owns the decoding: the log is arbitrary child stdout, and a `String` minted
/// from a slice starting mid-codepoint would break the type's invariant for
/// every later `string.*` call on the very path that reports why startup
/// failed.
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
  use bytes <- result.map(current_log_tail_bytes(path, started_at_ms, limit))
  string.trim(decode_log_tail(bytes, 3))
}

/// Decodes a log tail, discarding at most `budget` leading bytes to realign.
///
/// A byte offset lands inside a multi-byte codepoint at most three bytes after
/// its start, so dropping up to three leading bytes recovers a tail whose only
/// defect is where it was cut. Anything still undecodable is genuinely binary
/// output, and an empty diagnostic is a better answer than a broken `String`.
fn decode_log_tail(bytes: BitArray, budget: Int) -> String {
  case bit_array.to_string(bytes) {
    Ok(text) -> text
    Error(Nil) ->
      case budget > 0 {
        True -> decode_log_tail(slice_from(bytes, 1), budget - 1)
        False -> ""
      }
  }
}

/// Drops one leading byte, answering with the empty slice when there is none.
fn slice_from(bytes: BitArray, offset: Int) -> BitArray {
  case bit_array.slice(bytes, offset, bit_array.byte_size(bytes) - offset) {
    Ok(rest) -> rest
    Error(Nil) -> <<>>
  }
}

@external(erlang, "host_bootstrap_ffi", "current_log_tail")
fn current_log_tail_bytes(
  path: String,
  started_at_ms: Int,
  limit: Int,
) -> Result(BitArray, Nil)

/// Returns this process's real user id.
///
/// The BEAM exposes no `getuid`, and neither `simplifile` nor `gleam_erlang`
/// binds one, so the answer comes from `id -u`. It is the single fact the
/// private-file checks above cannot get from `stat` alone.
@external(erlang, "host_bootstrap_ffi", "current_uid")
fn current_uid() -> Result(Int, String)
