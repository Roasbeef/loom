//// A `process.call` that answers instead of crashing.
////
//// `gleam/erlang/process.call` panics on a timeout and on a callee that
//// died before replying, and that is the right default: a client whose
//// next step needs the reply is in an invalid state without it, and OTP
//// supervision absorbs the crash. Two places in this package want the
//// opposite, for the same reason in both — the caller is holding a
//// verdict it must deliver, and dying loses it.
////
//// The broker's congestion loop issues several exchanges against a
//// broker that is by construction at its busiest, and every one of them
//// is a candidate for the exchange that answers late. A borrower that
//// panics there takes the model's in-band refusal with it and settles
//// as a synthetic abort instead.
////
//// The helper pool's readiness probe runs inside the pool actor, so a
//// wedged helper that never answers would fault the pool — and with it
//// the broker, which borrows from the pool with a `process.call` of its
//// own. A probe is a question about a helper's health; it must not be
//// able to answer with the pool's death.
////
//// The cost of not crashing is one stale message: a callee that replies
//// after the timeout sends to a reply subject nobody is selecting on any
//// more, and the message sits in the caller's mailbox. That is bounded
//// by the number of late replies, which in both call sites is bounded by
//// the number of faulty peers, and it is a term rather than a leak of
//// anything live.

import gleam/erlang/process.{type Subject}
import gleam/result

/// Why an exchange produced no reply. Both variants mean the same thing
/// to a caller that needed one — nothing came back — but they are
/// distinct facts about the callee and a caller may want to say which.
pub type CallFault {
  /// The callee did not reply within the timeout. It may still be
  /// alive, and may still reply later.
  NoReply
  /// The callee was not alive to be sent to, or died before replying.
  CalleeGone
}

/// Sends `make_request` to `subject` and waits `timeout` milliseconds
/// for the reply, reporting a timeout or a dead callee rather than
/// panicking on either.
pub fn try_call(
  subject: Subject(message),
  waiting timeout: Int,
  sending make_request: fn(Subject(reply)) -> message,
) -> Result(reply, CallFault) {
  // A named subject with nothing registered under it has no owner to
  // monitor, which is `process.call`'s other panic and this function's
  // `CalleeGone`.
  use callee <- or_gone(process.subject_owner(subject))
  let reply_subject = process.new_subject()
  let monitor = process.monitor(callee)
  process.send(subject, make_request(reply_subject))
  let answer =
    process.new_selector()
    |> process.select_map(reply_subject, Ok)
    |> process.select_specific_monitor(monitor, fn(_down) { Error(CalleeGone) })
    |> process.selector_receive(timeout)
  // Demonitoring flushes a `DOWN` that arrived after the timeout, so the
  // only thing this exchange can leave behind is a late reply — see the
  // module doc on why that is a bounded term rather than a leak.
  process.demonitor_process(monitor)
  result.unwrap(answer, Error(NoReply))
}

// use callee <- or_gone(process.subject_owner(subject))
//
// Short-circuits an ownerless subject into the fault a dead callee
// produces, since a caller cannot tell the two apart and should not
// have to.
fn or_gone(
  owner: Result(process.Pid, Nil),
  then: fn(process.Pid) -> Result(a, CallFault),
) -> Result(a, CallFault) {
  case owner {
    Error(Nil) -> Error(CalleeGone)
    Ok(pid) -> then(pid)
  }
}
