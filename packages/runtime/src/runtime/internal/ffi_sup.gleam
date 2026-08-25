//// FFI confinement (spec §0.2): the runtime's only `@external`, in one
//// place. Nothing else in this package touches foreign code.

import gleam/erlang/process.{type Pid}

/// Asks a running OTP supervisor to terminate: its children are shut
/// down in reverse start order, each with an `exit(Child, shutdown)` and
/// the child spec's own grace period, and the supervisor then exits with
/// reason `shutdown`. OTP `sys:terminate/3` — a supervisor's only
/// graceful stop reachable from a process that is not its parent, and
/// the one thing `gleam/otp/static_supervisor` does not wrap. There is
/// no pure alternative: killing the supervisor pid instead propagates
/// `kill` to every child at once, which is the controlled crash this
/// exists to replace.
///
/// The supervisor answers the system message *before* it starts
/// terminating, so `Ok(Nil)` means the shutdown is under way; callers
/// wait for the pid to die. `Error(Nil)` covers a pid that was already
/// dead, a process that answers no system messages, and a shutdown that
/// outran `timeout_ms` — all of which leave the caller with the same
/// recourse, which is to kill.
@external(erlang, "runtime_ffi", "terminate_supervisor")
pub fn terminate_supervisor(
  supervisor supervisor: Pid,
  timeout_ms timeout_ms: Int,
) -> Result(Nil, Nil)
