//// A `process.call` that answers instead of crashing: a monitored
//// send-and-select against an actor that already exists.
////
//// `gleam/erlang/process.call` panics on a timeout and on a callee that
//// died before replying. That is the wrong default for a caller holding
//// something its own death would lose, and both protocol clients built on
//// this package's transport seam are called by exactly such callers: a
//// tool call's verdict (`mcp/client`), and a language-server query or a
//// post-edit diagnostics wait (`lsp/client`, ADR-013 §2). A dead or wedged
//// client must answer with a value the caller can report, never exit the
//// asker.
////
//// This is the shape of `broker/internal/call.try_call`, and it is the one
//// copy of it outside the broker. `mcp` deliberately does not depend on
//// `broker`, and `lsp` reuses this module rather than adding a third copy.
//// `docs/weft.md` names the gap — a monitored, non-panicking call against a
//// pre-existing pid — that weft should eventually fill, at which point
//// both copies collapse into it.
////
//// The cost of not crashing is one stale message: a callee that replies
//// after the wait sends to a reply subject nobody is selecting on any
//// more, and the message sits in the caller's mailbox as an inert term. It
//// is bounded by the number of late replies, which is bounded by the
//// number of faulty exchanges, and it is never a leak of anything live.

import gleam/erlang/process.{type Subject}
import gleam/result

/// Why an exchange produced no reply. Both mean "nothing came back" to a
/// caller that needed an answer, but they are distinct facts about the
/// callee and a caller may want to say which.
pub type CallFault {
  /// The callee did not reply within the wait. It may still be alive and
  /// may still reply later; that late reply is the stale message the
  /// module doc accounts for.
  NoReply

  /// The subject had no live owner to send to, or the owner died before
  /// replying.
  CalleeGone
}

/// Sends `make_request(reply_subject)` to `subject` and waits at most
/// `waiting` milliseconds for the reply, reporting a timeout or a dead
/// callee as a `CallFault` rather than panicking on either.
///
/// The callee is monitored for the length of the wait, so a callee that
/// dies mid-exchange answers `CalleeGone` at once rather than after the
/// full wait. On return the monitor is gone and any `DOWN` it produced has
/// been flushed; the only thing an exchange can leave behind is a late
/// reply.
///
/// ## Examples
///
/// ```gleam
/// // With an actor whose handler answers `Ask(reply)` with 42:
/// // call.try_call(subject, waiting: 100, sending: Ask) -> Ok(42)
/// //
/// // With a subject whose owner has exited:
/// // call.try_call(subject, waiting: 100, sending: Ask) -> Error(call.CalleeGone)
/// ```
///
pub fn try_call(
  subject: Subject(message),
  waiting timeout: Int,
  sending make_request: fn(Subject(reply)) -> message,
) -> Result(reply, CallFault) {
  // A subject whose owner is gone has nobody to answer; the monitor below
  // covers the owner dying after this check.
  use callee <- or_gone(process.subject_owner(subject))
  let reply_subject = process.new_subject()
  let monitor = process.monitor(callee)
  process.send(subject, make_request(reply_subject))
  let answer =
    process.new_selector()
    |> process.select_map(reply_subject, Ok)
    |> process.select_specific_monitor(monitor, fn(_down) { Error(CalleeGone) })
    |> process.selector_receive(timeout)

  // Demonitoring flushes a `DOWN` that arrived after the wait, so the only
  // thing this exchange can leave behind is a late reply.
  process.demonitor_process(monitor)
  result.unwrap(answer, Error(NoReply))
}

// use callee <- or_gone(process.subject_owner(subject))
//
// Short-circuits an ownerless subject into the fault a dead callee
// produces, since a caller cannot tell the two apart and should not have
// to.
fn or_gone(
  owner: Result(process.Pid, Nil),
  then: fn(process.Pid) -> Result(a, CallFault),
) -> Result(a, CallFault) {
  case owner {
    Error(Nil) -> Error(CalleeGone)
    Ok(pid) -> then(pid)
  }
}
