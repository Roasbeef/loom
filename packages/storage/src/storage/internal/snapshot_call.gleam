//// One finite exchange with the existing storage actor, without a worker.
////
//// The broker's internal/call module provides the in-tree precedent, but
//// storage cannot depend on the effect plane. Neither gleam_erlang nor Weft
//// exposes a total bounded call here. Keep this exchange local rather than
//// adding a dependency or changing the frozen Storage behavior.
////
//// A timeout ends only the caller's wait. The request may remain queued or
//// running, and one late reply may enter the caller's mailbox. The caller
//// must fail its original gateway/session and admit no further reads. Only
//// session custody can prove the original store drained before reopening it.

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
/// flushes a racing DOWN, but does not remove the request or its late reply.
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
