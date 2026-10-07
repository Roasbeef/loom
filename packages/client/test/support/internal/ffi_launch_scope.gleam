//// Test-only projection of the fixture's original native companion and scope.
//// Process links and stack witnesses have no Gleam API. The Erlang probe checks
//// the exact opaque representation and kills only this fixture's original scope.

import codemode/run_channel
import gleam/erlang/process

/// Projects the fixture-owned close closure's exact original companion.
@external(erlang, "client_test_ffi", "launch_companion")
pub fn companion(
  close: fn() -> run_channel.CloseResult,
) -> Result(process.Pid, Nil)

/// Terminates only the original native scope found under bounded stack witnesses.
@external(erlang, "client_test_ffi", "launch_kill_scope")
pub fn kill_scope(companion: process.Pid) -> Result(Nil, Nil)

/// Holds the fixture's original Broker reply without changing its queued call.
@external(erlang, "client_test_ffi", "launch_suspend_broker")
pub fn suspend_broker(pid: process.Pid) -> Result(Nil, Nil)

/// Restores that same original Broker after its reply has been lost.
@external(erlang, "client_test_ffi", "launch_resume_broker")
pub fn resume_broker(pid: process.Pid) -> Result(Nil, Nil)
