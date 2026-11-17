//// A `ClearCall` that needs no broker and no helper process.
////
//// The callers of the seam (the hook runner and the repository
//// observations) are tested here against a function the test builds. It
//// reports every call to a probe subject, the spec and the clearance wait
//// first, then the stdin the caller wrote and any cancel, and it answers
//// with the events a script gives for that spec. A script that answers no
//// events is a call that never settles, which is how the callers' bounded
//// waits and their cancel are driven.

import broker/broker
import client/clear_call.{type ClearCall}
import gleam/erlang/process.{type Subject}
import gleam/list
import tools/tool

/// What the fake saw, in the order it saw it.
pub type Seen {
  /// The call was cleared with this spec and clearance wait.
  Cleared(spec: broker.CallSpec, waiting: Int)

  /// The caller wrote a chunk and left stdin open.
  StdinChunk(data: BitArray)

  /// The caller wrote a chunk and closed stdin.
  StdinFinal(data: BitArray)

  /// The caller cancelled the call.
  Cancelled
}

/// Builds a fake that reports to `probe` and answers each call with the
/// events `script` gives for its spec.
///
/// The events are sent to the caller's subject before the function
/// returns, so a caller that collects after clearing finds them queued.
///
/// ## Examples
///
/// ```gleam
/// // let probe = process.new_subject()
/// // let clear = fake_clear_call.answering(probe, fn(_spec) { [] })
/// ```
///
pub fn answering(
  probe: Subject(Seen),
  script: fn(broker.CallSpec) -> List(broker.CallEvent),
) -> ClearCall {
  fn(spec, events, waiting) {
    process.send(probe, Cleared(spec:, waiting:))
    list.each(script(spec), process.send(events, _))
    Ok(
      tool.RunningCall(
        stdin: fn(data, eof) {
          case eof {
            True -> process.send(probe, StdinFinal(data))
            False -> process.send(probe, StdinChunk(data))
          }
        },
        cancel: fn() { process.send(probe, Cancelled) },
      ),
    )
  }
}
