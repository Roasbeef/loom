//// Work that goes on after the one who asked for it has stopped waiting
//// (protocol-change/107, slice 4b).
////
//// A seeded spawn has three jobs that are longer than the sender's window: a copy
//// made into a directory, a workspace put into a session on an executor, and a
//// finished child's commits captured and moved. Each is started by a request that
//// can wait for it only a little, and none may be cut short by the asker leaving:
//// they keep what they learned in a file, and the next ask reads it. This module
//// is the one place that starts such work and waits for it a bounded time.
////
//// ## What it does
////
//// `wait_for` starts the work in a process of its own that no one links to, so
//// the asker's end does not end it, and waits for its answer up to `wait_ms`. The
//// work bounds itself, with a deadline of its own through `weft` (`weft.deadline`,
//// `weft.start`), because only it knows what a deadline means for what it holds.
//// An answer that does not come in time is `Error(Nil)`, which the caller turns
//// into a request to ask again.
////
//// ## Why this is not a weft run
////
//// The work must survive its asker, including an asker that is killed when its own
//// deadline ends. `weft.start_detached`, `start_witnessed` and `start_relayed` each
//// spawn the run's scope linked to the process that starts it (`process.spawn` in
//// `run_scope`'s caller), so a killed starter takes the run with it, and weft has no
//// unlinked start. This helper therefore starts its worker with `process.spawn_unlinked`.
//// The bodies it runs bound themselves with `weft.deadline` and `weft.start` and
//// report every outcome, so the machinery weft owns is still weft's.

import gleam/erlang/process

/// Runs `work` in a process that outlives the asker, and waits at most `wait_ms`
/// for its answer. The work is not ended when the wait is.
///
/// ## Examples
///
/// ```gleam
/// // outliving.wait_for(fn() { 1 + 1 }, 1000) == Ok(2)
/// ```
pub fn wait_for(work: fn() -> a, wait_ms: Int) -> Result(a, Nil) {
  let reply = process.new_subject()
  let _worker = process.spawn_unlinked(fn() { process.send(reply, work()) })
  process.receive(reply, wait_ms)
}
