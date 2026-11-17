//// `client/clear_call` — the one function the owner's own non-tool work
//// uses to start a jailed process on the workspace's machine.
////
//// Imported hooks, the goal check and the repository observations each need
//// a cleared call: a process started under the session's policy, whose
//// output arrives as `CallEvent`s on a subject the caller owns. A `Broker`
//// they could call directly exists only where the workspace's broker is in
//// this VM, so they hold this function instead. It is the seam between what
//// they ask for and who answers: the caller supplies a spec, an events
//// subject and a clearance wait, and the placement decides what clears it.
////
//// The type lives here, and `client/workspace_plane` re-exports it as
//// `ClearCall`, because `worktree_diff` and `hookrunner` take it and
//// `workspace_plane` imports `worktree_diff`; a definition in
//// `workspace_plane` would make the import graph cyclic.

import broker/broker
import gleam/erlang/process.{type Subject}
import tools/tool

/// Clears one call and answers a running handle, or the broker's refusal.
///
/// The third argument is the clearance wait in milliseconds. A call that is
/// cleared delivers its events to the given subject and exactly one
/// `CallSettled`, the same contract the broker keeps. The returned
/// `RunningCall` carries `stdin` and `cancel` for that one call.
pub type ClearCall =
  fn(broker.CallSpec, Subject(broker.CallEvent), Int) ->
    Result(tool.RunningCall, broker.Refusal)

/// The clearing function over a broker this VM holds.
///
/// It is `tool.broker_runner` with the wait taken per call, so a caller
/// that owns its own deadline passes it instead of a figure fixed when the
/// plane was built.
///
/// ## Examples
///
/// ```gleam
/// // let clear = clear_call.over_broker(plane.broker)
/// // let assert Ok(call) = clear(spec, events, 5000)
/// // call.stdin(<<>>, True)
/// ```
///
pub fn over_broker(broker_actor: broker.Broker) -> ClearCall {
  fn(spec, events, waiting) {
    tool.broker_runner(broker: broker_actor, waiting:)(spec, events)
  }
}
