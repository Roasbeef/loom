//// FFI confinement (spec §0.2): every `@external` the server entry
//// point needs, in one place. Each declaration names the OTP function
//// behind it and why no pure alternative exists. Nothing else in this
//// package touches foreign code.

import gleam/erlang/process.{type Pid}

/// Wall-clock milliseconds since the Unix epoch, for the server's
/// injected `Clock`. OTP `erlang:system_time(millisecond)` via the
/// package FFI — time is an ambient OS fact; §0.2 requires it injected
/// from exactly one place, and this is that place for `client/serve`.
@external(erlang, "client_ffi", "system_time_ms")
pub fn system_time_ms() -> Int

/// A strictly increasing positive integer, for the server's injected
/// entropy seam (seeds must never repeat within a session lifetime —
/// spec-gaps WP-E item 6). OTP
/// `erlang:unique_integer([positive, monotonic])`; no pure function can
/// promise VM-wide uniqueness.
@external(erlang, "client_ffi", "unique_positive_integer")
pub fn unique_positive_integer() -> Int

/// Resolves an executable name against `PATH`, for the default
/// `loom-exec` helper lookup. OTP `os:find_executable/1`; `PATH`
/// resolution is an OS question with no pure answer.
@external(erlang, "client_ffi", "find_executable")
pub fn find_executable(name: String) -> Result(String, Nil)

/// Blocks the calling process until the OS delivers `SIGTERM`, so the
/// server can close its runtime (releasing the session lease) before
/// the VM exits. OTP `os:set_signal/2` plus a `gen_event` handler
/// swapped into `erl_signal_server` — signal delivery is inherently a
/// runtime-system affair. Swapping replaces the default handler, whose
/// response to `SIGTERM` is an immediate `init:stop()`; ours forwards
/// the signal here instead so shutdown runs in order.
@external(erlang, "client_ffi", "wait_for_sigterm")
pub fn wait_for_sigterm() -> Nil

/// Stops the VM with the given exit code, for startup failures that
/// have already printed their reason (§0.2 permits a documented halt in
/// an entry point — there is nothing to supervise before the tree
/// exists). OTP `erlang:halt/1`; the return type is a free variable
/// because the call never returns.
@external(erlang, "client_ffi", "halt")
pub fn halt(code: Int) -> anything

/// Asks a running OTP supervisor to terminate: children are shut down in
/// reverse start order, each with an `exit(Child, shutdown)` and its
/// child spec's grace, and the supervisor then exits `shutdown`. OTP
/// `sys:terminate/3` — a supervisor's only graceful stop reachable from
/// a process that is not its parent, and the one thing
/// `gleam/otp/static_supervisor` does not wrap. No pure alternative
/// exists: killing the pid instead propagates `kill` to every child at
/// once, which is the controlled crash this replaces.
///
/// `Ok(Nil)` means the shutdown is under way, not that the tree is gone;
/// the caller waits for the pid to die. `Error(Nil)` covers an
/// already-dead pid and a shutdown that outran the timeout alike, and
/// leaves the caller to kill.
@external(erlang, "client_ffi", "terminate_supervisor")
pub fn terminate_supervisor(
  supervisor supervisor: Pid,
  timeout_ms timeout_ms: Int,
) -> Result(Nil, Nil)

/// The host's operating system name and machine architecture, raw:
/// `#("linux", "x86_64-pc-linux-gnu")`, `#("darwin",
/// "aarch64-apple-darwin23.6.0")`. OTP `os:type/0` and
/// `erlang:system_info(system_architecture)` — both are ambient facts of
/// the running system, and the system prompt needs them because an agent
/// that does not know its platform guesses at command syntax.
///
/// Deliberately unnormalized: `client/system_prompt.platform` turns the
/// pair into the label the prompt carries, so the mapping is a pure
/// function with tests rather than a line of Erlang.
@external(erlang, "client_ffi", "platform")
pub fn platform() -> #(String, String)

/// The root directory of the installation this VM is running out of.
/// OTP `code:root_dir/0` — for a release it is the unpacked release
/// tree, for every other run it is the OTP installation the emulator
/// came from. There is no pure answer: it is the `ROOTDIR` the emulator
/// resolved for itself at boot, and it is the only anchor that survives
/// being invoked through a launcher, a symlink, or from any working
/// directory. `client/install` turns it into paths.
@external(erlang, "client_ffi", "code_root_dir")
pub fn code_root_dir() -> String

/// The running emulator's ERTS version, e.g. `"17.0.5"`. OTP
/// `erlang:system_info(version)` — an ambient fact of the running
/// system. It names the `erts-<version>` directory under
/// `code_root_dir()`, which is how `client/install` reaches the very
/// emulator that is executing this code without globbing for it.
@external(erlang, "client_ffi", "erts_version")
pub fn erts_version() -> String
