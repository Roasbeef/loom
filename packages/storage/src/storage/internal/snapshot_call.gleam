//// One finite exchange with the existing storage actor, made by its caller.
////
//// The broker's internal/call module provides the in-tree precedent, but
//// storage cannot depend on the effect plane. Neither gleam_erlang nor Weft
//// exposes a total bounded call here. Keep this exchange local rather than
//// adding a dependency or changing the frozen Storage behavior.
////
//// The exchange spawns no worker of its own, so the process that calls it
//// owns the reply subject, and what happens to a late reply depends on who
//// that process is. A timeout ends only the caller's wait. The request may
//// remain queued or running, and one late reply enters the mailbox of the
//// process that made the call. A caller that is a long-lived actor therefore
//// receives a message it never selected, which is how a slow capture once
//// left stray replies in the client gateway. Such a caller must not make the
//// exchange itself: it asks from a short-lived process, a weft run, which
//// exits when the exchange does, and the late reply is dropped with it. The
//// gateway's transfer capture does exactly that. The remaining synchronous
//// callers are small exact-key reads that still take the late reply.
////
//// A timeout is a deadline and nothing more: only the monitor proves the
//// storage actor dead, and that is reported as ReaderUnavailable instead.
//// Because every exchange uses its own reply subject, repeating a read after
//// a timeout cannot be satisfied by an earlier read's late answer. Whether the
//// original store has drained before it is reopened is still a question only
//// session custody can answer.

import gleam/bool
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/result
import storage/snapshot

/// Upper bound on one exchange, including time spent behind queued writes.
pub const maximum_wait_ms = 5000

/// Exchange one snapshot request, preserving backend errors without panics.
///
/// A nonpositive budget refuses before sending. A unique reply subject keeps
/// a late response from satisfying another exchange. Releasing the monitor
/// flushes a racing DOWN, but does not remove the request or its late reply,
/// which is delivered to the calling process and dies with it.
///
/// ## Examples
///
/// ```gleam
/// // snapshot_call.read(handle, waiting: remaining_ms, sending: Capture(plan, _))
/// ```
pub fn read(
  handle: Subject(message),
  waiting timeout_ms: Int,
  sending request: fn(Subject(Result(value, snapshot.Error))) -> message,
) -> Result(value, snapshot.Error) {
  use <- bool.guard(
    when: timeout_ms <= 0,
    return: Error(snapshot.InvalidRequest),
  )
  use owner <- result.try(
    process.subject_owner(handle)
    |> result.map_error(fn(_error) { snapshot.ReaderUnavailable }),
  )
  let reply = process.new_subject()
  let monitor = process.monitor(owner)
  process.send(handle, request(reply))

  // The monitor precedes the send, so death on either side of admission has
  // a total result. A timeout retains no monitor but may retain actor work.
  let answer =
    process.new_selector()
    |> process.select(reply)
    |> process.select_specific_monitor(monitor, fn(_down) {
      Error(snapshot.ReaderUnavailable)
    })
    |> process.selector_receive(int.min(timeout_ms, maximum_wait_ms))
  process.demonitor_process(monitor)
  result.unwrap(answer, Error(snapshot.ReadTimedOut))
}
