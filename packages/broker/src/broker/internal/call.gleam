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

import gleam/dynamic
import gleam/erlang/atom
import gleam/erlang/process.{type ExitReason, type Subject}
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

/// Why an exchange produced no reply, with what the callee's `DOWN`
/// said when it carried a reason. `try_call` folds this into a
/// `CallFault`; a caller that must tell a callee on a node that is no
/// longer connected from one that died uses `try_call_watching`.
pub type Unanswered {
  /// The callee did not reply within the timeout.
  TimedOut

  /// The subject had no owner to send to.
  NoCallee

  /// The callee's monitor fired with this reason before it replied. A
  /// callee on another node whose connection dropped exits with
  /// `noconnection` here (`is_disconnection`).
  CalleeDown(reason: ExitReason)
}

/// Sends `make_request` to `subject` and waits `timeout` milliseconds
/// for the reply, reporting a timeout or a dead callee rather than
/// panicking on either.
///
/// ## Examples
///
/// ```gleam
/// // call.try_call(subject, waiting: 1000, sending: Ask)
/// ```
pub fn try_call(
  subject: Subject(message),
  waiting timeout: Int,
  sending make_request: fn(Subject(reply)) -> message,
) -> Result(reply, CallFault) {
  try_call_watching(subject, waiting: timeout, sending: make_request)
  |> result.map_error(fault_of)
}

/// `try_call`, keeping the reason the callee's monitor gave when it went
/// down before replying.
///
/// ## Examples
///
/// ```gleam
/// // call.try_call_watching(subject, waiting: 1000, sending: Ask)
/// ```
pub fn try_call_watching(
  subject: Subject(message),
  waiting timeout: Int,
  sending make_request: fn(Subject(reply)) -> message,
) -> Result(reply, Unanswered) {
  // A named subject with nothing registered under it has no owner to
  // monitor, which is `process.call`'s other panic and this function's
  // `NoCallee`.
  case process.subject_owner(subject) {
    Error(Nil) -> Error(NoCallee)
    Ok(callee) -> {
      let reply_subject = process.new_subject()
      let monitor = process.monitor(callee)
      process.send(subject, make_request(reply_subject))
      let answer =
        process.new_selector()
        |> process.select_map(reply_subject, Ok)
        |> process.select_specific_monitor(monitor, fn(down) {
          Error(CalleeDown(reason_of(down)))
        })
        |> process.selector_receive(timeout)

      // Demonitoring flushes a `DOWN` that arrived after the timeout, so the
      // only thing this exchange can leave behind is a late reply — see the
      // module doc on why that is a bounded term rather than a leak.
      process.demonitor_process(monitor)
      result.unwrap(answer, Error(TimedOut))
    }
  }
}

/// The `CallFault` an unanswered exchange stands for: a timeout is
/// `NoReply`, and a callee that was never there or went down is
/// `CalleeGone`.
///
/// ## Examples
///
/// ```gleam
/// assert call.fault_of(call.TimedOut) == call.NoReply
/// ```
pub fn fault_of(unanswered: Unanswered) -> CallFault {
  case unanswered {
    TimedOut -> NoReply
    NoCallee | CalleeDown(..) -> CalleeGone
  }
}

/// Whether an exit reason is the `noconnection` a monitor of a process
/// on another node reports when the distribution connection to that
/// node drops. The process may be alive; only the link is gone.
///
/// ## Examples
///
/// ```gleam
/// assert !call.is_disconnection(process.Normal)
/// ```
pub fn is_disconnection(reason: ExitReason) -> Bool {
  case reason {
    process.Abnormal(detail) -> detail == noconnection()
    process.Normal | process.Killed -> False
  }
}

fn noconnection() -> dynamic.Dynamic {
  atom.to_dynamic(atom.create("noconnection"))
}

// A monitor of a process and one of a port both report the reason the
// monitored thing exited with.
fn reason_of(down: process.Down) -> ExitReason {
  case down {
    process.ProcessDown(reason:, ..) -> reason
    process.PortDown(reason:, ..) -> reason
  }
}
