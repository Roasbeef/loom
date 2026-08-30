//// FFI confinement (spec §0.2): the runtime's only `@external`s, in one
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
/// outran `timeout_ms`. The runtime still observes the PID after either
/// result; it must never replace an inconclusive provider drain with `kill`.
@external(erlang, "runtime_ffi", "terminate_supervisor")
pub fn terminate_supervisor(
  supervisor supervisor: Pid,
  timeout_ms timeout_ms: Int,
) -> Result(Nil, Nil)

/// Sends `message` to an already-resolved `pid`, once, with no name
/// lookup at all. `gleam/erlang/process.send` re-resolves a `Subject`
/// backed by a *name* on every call — this is `runtime/writer.publish`'s
/// escape from that: resolve a subscriber's name to a pid exactly once
/// (`process.named`), build the same envelope `process.send` would have
/// built (`#(name, message)`), and hand both to this rather than to
/// `process.send`, which would look the name up again. There is no pure
/// alternative: reaching a specific, already-known pid without a second
/// lookup needs the bare `!`, which no wrapped `Subject`-taking function
/// in `gleam_erlang` exposes.
///
/// Erlang's `!` to a pid that has already exited is a silent no-op, which
/// is what makes this safe with no aliveness check of its own: nothing
/// past the name lookup can crash the caller, and that lookup already
/// happened before this is called (issue #43).
@external(erlang, "runtime_ffi", "send_to_pid")
pub fn send_to_pid(pid pid: Pid, message message: message) -> Nil
