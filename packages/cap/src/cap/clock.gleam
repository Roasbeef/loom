//// `cap/clock` — waiting, and the one prelude module that calls no
//// capability.
////
//// Every other `cap/*` module is an RPC stub: it marshals its arguments
//// into a `cap_call`, crosses the AF_UNIX channel, and is answered by a
//// broker that checked a policy first. This one makes no call and no
//// round trip, because sleeping asks nothing of the harness. A program
//// that waits spends its own invocation's deadline and nothing else —
//// no budget, no file, no socket, no durable cell — so there is no
//// authority here for a policy to grant or refuse, and inventing a
//// capability name for it would put a check in front of a thing with
//// nothing to check.
////
//// It is on the prelude because the extension seam has no other way to
//// pace itself. An extension answering a hook often has to poll: ask a
//// local daemon whether an invoice settled, look again, and give up when
//// the invocation's deadline runs out. Without a sleep, the only shapes
//// available are a busy loop, which burns the satellite's scheduler for
//// the whole wait, and a timer built out of the process primitives the
//// vetting allowlist deliberately withholds. So the choice is not
//// "sleep or no sleep" but "sleep, or a spin loop"; the spin loop is
//// worse for everyone and grants no less.
////
//// There is deliberately no clock reading here. A program cannot ask
//// what time it is, because the harness puts the timestamp on the
//// payload of the hook it is answering — the one instant that is
//// meaningful to an invocation is the one the harness observed, and
//// handing the program a second, satellite-local reading of a different
//// clock would only let the two disagree.

import gleam/erlang/process

/// Blocks the calling process for `ms` milliseconds, then returns. A
/// negative or zero `ms` returns at once rather than failing, so a
/// duration computed as "the deadline minus now" needs no guard at the
/// call site when it has already passed.
///
/// This blocks one process, never the node: a `cap/task` branch or a
/// `cap/actor` handler sleeping leaves every other process running, and
/// the satellite's channel keeps answering. Nothing here extends the
/// invocation's deadline, so a sleep longer than the time left simply
/// ends with the invocation.
///
/// ## Examples
///
/// ```gleam
/// clock.sleep_ms(50)
/// clock.sleep_ms(-1)
/// ```
///
pub fn sleep_ms(ms: Int) -> Nil {
  case ms > 0 {
    True -> process.sleep(ms)
    False -> Nil
  }
}
